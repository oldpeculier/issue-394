# first run: ./test.sh
# then run: ./test.sh ondrej
# Install nginx and rabbitmq
repo=$1
if [ "$repo" == "ondrej" ]; then
  sudo add-apt-repository -y "ppa:ondrej/php5"
else
  sudo rm -f /etc/apt/sources.list.d/ondrej-php5*
  sudo apt-get autoremove php5 php5-cli -y
fi
sudo apt-get update
sudo apt-get install rabbitmq-server php5 php5-cli -y

# Create some SSL certs
export CAPASSPHRASE=secret # for signing
export CAORG="PHP-AMQPLIB"
export CACN="PHP-AMQPLIB Certificate Authority"
export KEYSIZE=2048
export WORKSPACE="./workspace"
export CAKEY="$WORKSPACE/ca.key"
export CAFILE="$WORKSPACE/ca.crt"
publicip=`curl -ss ipinfo.io/ip`

cd $WORKSPACE
rm -f *
cd - 
cat /dev/null > $WORKSPACE/index.txt
serial=`printf "%03x%03x%03x%03x" $((RANDOM%4096)) $((RANDOM%4096)) $((RANDOM%4096)) $((RANDOM%4096))`
echo -n $serial > "$WORKSPACE/serial"
# Self-signed CA
openssl req -days 365 -new -x509 -passout pass:$CAPASSPHRASE -keyout $CAKEY \
  -out $CAFILE -config ./openssl.cnf -subj "/C=US/O=$CAORG/CN=$CACN"

# Generate a CSR
openssl req -days 365 -new -keyout $WORKSPACE/server.key -out $WORKSPACE/server.csr \
  -extensions server_ca_extensions -config ./openssl.cnf -nodes \
  -subj "/OU=Servers/CN=$publicip" 

# Sign the cert
openssl ca -days 365 -notext -batch -out $WORKSPACE/server.crt -in $WORKSPACE/server.csr \
  -extensions server_ca_extensions -config ./openssl.cnf -passin pass:$CAPASSPHRASE \
  -subj "/OU=Servers/CN=$publicip"

# Configure rabbit on SSL
[ ! -d /etc/rabbitmq/ssl ] && \
  sudo install -d -o rabbitmq -g rabbitmq -m 755 /etc/rabbitmq/ssl

sudo install -o rabbitmq -g rabbitmq -m 644 $WORKSPACE/ca.crt /etc/rabbitmq/ssl/ca.crt
sudo install -o rabbitmq -g rabbitmq -m 644 $WORKSPACE/server.crt /etc/rabbitmq/ssl/server.crt
sudo install -o rabbitmq -g rabbitmq -m 600 $WORKSPACE/server.key /etc/rabbitmq/ssl/server.key

[ ! -f /etc/rabbitmq/rabbitmq.config ] && \
  sudo install -o rabbitmq -g rabbitmq -m 644 /dev/null /etc/rabbitmq/rabbitmq.config

sudo su -c "cat << EOF > /etc/rabbitmq/rabbitmq.config
[
  {rabbit, [
    {ssl_listeners, [5671]},
    {ssl_options, [{cacertfile,\"/etc/rabbitmq/ssl/ca.crt\"},
                  {certfile,\"/etc/rabbitmq/ssl/server.crt\"},
                  {keyfile,\"/etc/rabbitmq/ssl/server.key\"},
                  {fail_if_no_peer_cert,false}]}
  ]},
  {log_levels, [
    {connection, debug}
  ]}
].
EOF"

sudo service rabbitmq-server restart

# do some checks
echo '\n' | openssl s_client -connect 127.0.0.1:5671
openssl verify -CAfile /etc/rabbitmq/ssl/ca.crt /etc/rabbitmq/ssl/server.crt

# Now create and run the php test
cat << EOF > ./test.php
<?php
\$cafile = "$WORKSPACE/ca.crt";
\$host = "$publicip";
\$port = "5671";
\$context = stream_context_create(array('ssl'=>array('cafile'=>\$cafile, 'verify_peer'=>true)));
\$sock = stream_socket_client("ssl://".\$host.":".\$port,\$errno,\$errstr,10,STREAM_CLIENT_CONNECT,\$context);
if (\$sock) {
  echo "\n***********\nCONNECTED!\n***********\n\n";
} else {
  echo "\$errno - \$errstr\n";
}
?>
EOF
chmod 755 ./test.php
php test.php
php -v
