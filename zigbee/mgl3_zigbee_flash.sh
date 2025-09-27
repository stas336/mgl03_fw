#!/bin/sh

DEV=/dev/ttyS2

send() {
  echo -en "$1" > $DEV
}

reset() {
  send '\x1A\xC0\x38\xBC\x7E'
}

send_v4() {
  send '\x00\x42\x21\xa8\x50\xed\x2c\x7e'
}

send_v7() {
  send '\x7d\x31\x43\x21\x57\x54\x2a\x12\x05\x87\x7e'
}

send_v8() {
  send '\x7d\x31\x43\x21\xa9\x54\x2a\x1d\xc9\x7f\x7e'
}

send_v13() {
  send '\x7d\x31\x42\x21\xa9\x54\x2a\x7d\x38\xdc\x7a\x7e'
}

to_btl_7() {
  echo "Rebooting to bootloader"
  send '\x22\x40\x21\x57\x54\xa5\x14\x21\x08\x7e'
}

to_btl_8() {
  echo "Rebooting to bootloader"
  send '\x22\x40\x21\xa9\xdb\x2a\x14\x00\xd2\x7e'
}

to_btl_13() {
  echo "Rebooting to bootloader"
  send '\x22\x43\x21\xa9\x7d\x33\x2a\x16\xb2\x59\x94\xe7\x9e\x7e'
}

ack1() {
  send '\x81\x60\x59\x7E'
}

ack2() {
  send '\x82\x50\x3A\x7E'
}

upload_gbl() {
  echo "Sending upload command"
  send '1'
}

restart() {
  echo "Sending restart command"
  send '2'
}

read_file() {
  CNT=${1:-0}
  FILE=${2:-$DEV}
  NUM_PARAM="-w1"
  if [ "x$CNT" != "x0" ]; then
    NUM_PARAM="-N $CNT -w$CNT"
  fi
  $BUSYBOX od -A n -t x1 $NUM_PARAM $FILE
}

skip_response() {
  read_file $1 > /dev/null
}

read_all() {
  $BUSYBOX od -A n -t x1 $DEV
}

get_version() {
  reset
  skip_response 7
  send_v4
  response=$(read_file 11)
  ack1
  ver_byte=$(echo $response | cut -d' ' -f5)
  if [ "x$ver_byte" = "x5c" ]; then
    echo 8
  elif [ "x$ver_byte" = "x5d" ]; then
    echo 13
  else
    echo 7
  fi
}

download_curl() {
  echo -n "curl doesn't exists, downloading..."
  printf 'GET /files/curl HTTP/1.1\r\nHost: mipsel-ssl.vacuumz.info\r\nUser-Agent: Wget/1.20.3\r\nConnection: close\r\n\r\n' |\
   openssl s_client \
    -quiet -tls1_1 \
    -connect mipsel-ssl.vacuumz.info:443 \
    -servername mipsel-ssl.vacuumz.info 2>/dev/null |\
   sed '/alt-svc.*/d' |\
   tail -n +19 > /tmp/curl && chmod +x /tmp/curl
  export PATH="$PATH:/tmp"
  echo "done!"
}

download_tools() {
  echo -n "Downloading $1..."
  CURL=$(which curl)
  if [ "x$CURL" = "x" ]; then
    download_curl
  fi
  curl -k "https://mipsel-ssl.vacuumz.info/files/$1" -o "/data/$1" && chmod +x "/data/$1"
  echo "done!"
}

# some preparations

BUSYBOX="/data/busybox"
if [ ! -f "$BUSYBOX" ]; then
  download_tools busybox
fi

if [ ! -x "$BUSYBOX" ]; then
  chmod +x "$BUSYBOX"
fi

SX=$(which sx)
if [ "x$SX" = "x" ]; then
  SX=/data/sx
fi

if [ ! -f "$SX" ]; then
  download_tools sx
  download_tools libnsl.so.0
  export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/data
fi

if [ ! -x "$SX" ]; then
  chmod +x "$SX"
fi


echo ""
echo "Xiaomi Gateway 3 (mgl3) Zigbee firmware flashing script"
echo ""
echo "Found firmware files:"
pos=1
for f in $(ls *.gbl); do
  HEADER=$(read_file 4 $f)
  if [ "x$HEADER" = "x eb 17 a6 03" ]; then
    echo "$pos: $f"
    eval "firmware$pos=$f"
    pos=$((pos+1))
  fi
done
FIRMWARE_FILE=""
while [ -z $FIRMWARE_FILE ]; do
  read -p "Select firmware: " choice
  FIRMWARE_FILE=$(eval "echo \$firmware$choice")
done
echo "You selected: $FIRMWARE_FILE"
echo ""

echo "Preparing"
echo "Killing default zigbee software"

killall socat
killall ser2net
killall daemon_app.sh
killall Lumi_Z3GatewayHost_MQTT

echo "Done"

echo ""
echo "Press Ctrl+C to cancel in 5 seconds!"
sleep 5

echo ""

VERSION=$(get_version)
echo "Detected EZSP v$VERSION"

if [ "v$VERSION" = "v7" ]; then
  send_v7
  ack2
  to_btl_7
elif [ "v$VERSION" = "v8" ]; then
  send_v8
  ack2
  to_btl_8
elif [ "v$VERSION" = "v13" ]; then
  send_v13
  ack2
  to_btl_13
fi

upload_gbl
$SX -vv -X -b "$FIRMWARE_FILE" < $DEV > $DEV

sleep 1
restart

sleep 3
VERSION=$(get_version)
echo "Detected EZSP v$VERSION"

echo ""
echo "Flashing completed!"
echo ""
echo "Reload XiaomiGateway3 integration or restart Home Assistant"
IP_ADDR=$(ifconfig br0 | grep "inet addr" | cut -d":" -f2 | cut -d" " -f1)
echo "Configure zigbee2mqtt port address to: tcp://$IP_ADDR:8888"