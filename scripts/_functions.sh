#!/bin/bash

# paths
walletPath="/home/joinmarket/.joinmarket/wallets/"

# versions
currentJBcommit=$(cd /home/joinmarket/joininbox; git describe --tags)
currentJBtag=$(cd ~/joininbox; git tag | sort -V | tail -1)
currentJMversion=$(cd /home/joinmarket/joinmarket-clientserver 2>/dev/null; \
git describe --tags 2>/dev/null)

function openMenuIfCancelled() {
  pressed=$1
  case $pressed in
    1)
      echo "# Cancelled"
      echo "# Returning to the menu..."
      sleep 1
      /home/joinmarket/menu.sh
      exit 1;;
    255)
      echo "# ESC pressed."
      echo "# Returning to the menu..."
      sleep 1
      /home/joinmarket/menu.sh
      exit 1;;
  esac
}

function errorOnInstall() {
  if [ "$1" -gt 0 ]; then
    DIALOGRC=.dialogrc.onerror dialog --title "Error during install" \
      --msgbox "\nPlease search or report at:\n https://github.com/openoms/joininbox/issues" 7 56
  fi
}

function passwordToFile() {
  # write password into a file (to be shredded)
  # get password
  data=$(mktemp 2>/dev/null)
  # trap it
  trap 'rm -f $data' 0 1 2 5 15
  dialog --backtitle "Enter password" \
        --title "Enter password" \
        --insecure \
        --passwordbox "Type or paste the wallet decryption password" 8 52 2> "$data"
  # make decison
  pressed=$?
  case $pressed in
    0)
      touch /home/joinmarket/.pw
      chmod 600 /home/joinmarket/.pw
      tee /home/joinmarket/.pw 1>/dev/null < "$data"
      shred "$data"
      ;;
    1)
      shred "$data"
      shred "$wallet"
      rm -f .pw
      echo "# Cancelled"
      exit 1
      ;;
    255)
      shred "$data"
      shred "$wallet"
      rm -f .pw
      [ -s "$data" ] &&  cat "$data" || echo "# ESC pressed."
      exit 1
      ;;
  esac
}

function chooseWallet() {
source /home/joinmarket/joinin.conf
  wallet=$(mktemp 2>/dev/null)
  if [ "$defaultWallet" = "off" ]; then
    wallet=$(mktemp 2>/dev/null)
    dialog --backtitle "Choose a wallet by typing the full name of the file" \
    --title "Choose a wallet by typing the full name of the file" \
    --fselect "$walletPath" 10 60 2> "$wallet"
    openMenuIfCancelled $?
  else
    echo "$defaultWallet" > "$wallet"
  fi
}

function stopYG() {
  # stop the background process (equivalent to CTRL+C)
  # use wallet from joinin.conf
  source /home/joinmarket/joinin.conf
  pkill -sigint -f "python yg-privacyenhanced.py $YGwallet --wallet-password-stdin"
  # pgrep python | xargs kill -sigint             
  # remove the service
  sudo systemctl stop yg-privacyenhanced
  sudo systemctl disable yg-privacyenhanced
  # check for failed services
  # sudo systemctl list-units --type=service
  sudo systemctl reset-failed
  # make sure the lock file is deleted 
  rm -f ~/.joinmarket/wallets/.$wallet.lock
  # for old version <v0.6.3
  rm -f ~/.joinmarket/wallets/$wallet.lock 2>/dev/null
  echo "# Stopped the Yield Generator background service"
}

function QRinTerminal() {
  datastring=$1
  if [ ${#datastring} -eq 0 ]; then
    echo "# Error='missing string'"
  fi
  qrencode -t ANSI256 "${datastring}"
  echo "(To shrink QR code: MacOS press CMD- / Linux press CTRL-)"
}

function feereport() {
  # puts the fees earned as a Maker into variables
  INPUT=/home/joinmarket/.joinmarket/logs/yigen-statement.csv
  allEarned=0
  allCoinjoins=0
  monthEarned=0
  monthCoinjoins=0
  weekEarned=0
  weekCoinjoins=0
  dayEarned=0
  dayCoinjoins=0
  unixtimeMonthAgo=$(date -d "1 month ago" +%s)
  unixtimeWeekAgo=$(date -d "1 week ago" +%s)
  unixtimeDayAgo=$(date -d "1 day ago" +%s)
  OLDIFS=$IFS
  IFS=","
  [ ! -f $INPUT ] && { echo "$INPUT file not found"; exit 99; }
  #timestamp            cj amount/satoshi  my input count  my input value/satoshi  cjfee/satoshi  earned/satoshi  confirm time/min  notes
  while read -r timestamp cj_amount_satoshi my_input_count my_input_value_satoshi  cjfee_satoshi  earned_satoshi  confirm_time_min  notes
  do
    unixtimeEvent=$(date -d "$timestamp" +%s 2>/dev/null)
    if [ "$earned_satoshi" -gt 0 ]; then
      allEarned=$(( allEarned + earned_satoshi ))
      allCoinjoins=$(( allCoinjoins + 1 ))
      if [ "$unixtimeEvent" -gt "$unixtimeMonthAgo" ]; then
        monthEarned=$(( monthEarned + earned_satoshi ))
        monthCoinjoins=$(( monthCoinjoins + 1 ))
        if [ "$unixtimeEvent" -gt "$unixtimeWeekAgo" ]; then
          weekEarned=$(( weekEarned + earned_satoshi ))
          weekCoinjoins=$((weekCoinjoins+1))
          if [ "$unixtimeEvent" -gt "$unixtimeDayAgo" ]; then
            dayEarned=$((dayEarned+earned_satoshi))
            dayCoinjoins=$((dayCoinjoins+1))
          fi
        fi
      fi
    fi 2>/dev/null
  done < "$INPUT"
  IFS=$OLDIFS
}

function YGuptime() {
  # puts the Yield Generator uptime to $JMUptime
  source /home/joinmarket/joinin.conf
  JMpid=$(pgrep -f "python yg-privacyenhanced.py $YGwallet --wallet-password-stdin" 2>/dev/null | head -1)
  JMUptimeInSeconds=$(ps -p $JMpid -oetime= 2>/dev/null | tr '-' ':' | awk -F: '{ total=0; m=1; } { for (i=0; i < NF; i++) {total += $(NF-i)*m; m *= i >= 2 ? 24 : 60 }} {print total}')
  JMUptime=$(printf '%dd:%dh:%dm\n' $((JMUptimeInSeconds/86400)) $((JMUptimeInSeconds%86400/3600)) $((JMUptimeInSeconds%3600/60)))
}

# installJoinMarket [update|testPR <PRnumber>|commit]
function installJoinMarket() {
  source /home/joinmarket/joinin.conf
  cd /home/joinmarket
  # PySide2 for armf: https://packages.debian.org/buster/python3-pyside2.qtcore
  echo "# Installing ARM specific dependencies to run the QT GUI"
  sudo apt install -y python3-pyside2.qtcore python3-pyside2.qtgui \
  python3-pyside2.qtwidgets zlib1g-dev libjpeg-dev python3-pyqt5 libltdl-dev
  # https://github.com/JoinMarket-Org/joinmarket-clientserver/issues/668#issuecomment-717815719
  sudo apt -y install build-essential automake pkg-config libffi-dev python3-dev libgmp-dev 
  sudo -u joinmarket pip install libtool asn1crypto cffi pycparser coincurve
  echo "# installing JoinMarket"
  
  if [ "$1" = "update" ] || [ "$1" = "testPR" ] || [ "$1" = "commit" ]; then
    echo "# Deleting the old source code (joinmarket-clientserver directory)"
    sudo rm -rf /home/joinmarket/joinmarket-clientserver
  fi
  
  sudo -u joinmarket git clone https://github.com/Joinmarket-Org/joinmarket-clientserver
  cd joinmarket-clientserver
  
  if [ "$1" = "testPR" ]; then
    PRnumber=$2
    echo "# Using the PR:"
    echo "# https://github.com/JoinMarket-Org/joinmarket-clientserver/pull/$PRnumber"
    git fetch origin pull/$PRnumber/head:pr$PRnumber
    git checkout pr$PRnumber
  elif [ "$1" = "commit" ]; then
    echo "# Updating to the latest commit in:"
    echo "# https://github.com/JoinMarket-Org/joinmarket-clientserver"
  else
    JMVersion="v0.8.0"
    sudo -u joinmarket git reset --hard $JMVersion
  fi

  # do not stop at installing debian dependencies
  sudo -u joinmarket sed -i \
  "s#^        if ! sudo apt-get install \${deb_deps\[@\]}; then#\
        if ! sudo apt-get install -y \${deb_deps\[@\]}; then#g" install.sh
  
  if [ ${cpu} != "x86_64" ]; then
    echo "# Make install.sh set up jmvenv with -- system-site-packages on arm"
    # and import the PySide2 armf package from the system
    sudo -u joinmarket sed -i "s#^    virtualenv -p \"\${python}\" \"\${jm_source}/jmvenv\" || return 1#\
      virtualenv --system-site-packages -p \"\${python}\" \"\${jm_source}/jmvenv\" || return 1 ;\
    /home/joinmarket/joinmarket-clientserver/jmvenv/bin/python -c \'import PySide2\'\
    #g" install.sh
    # don't install PySide2 - using the system-site-package instead 
    sudo -u joinmarket sed -i "s#^PySide2.*##g" requirements/gui.txt
    # don't install PyQt5 - using the system package instead 
    sudo -u joinmarket sed -i "s#^PyQt5.*##g" requirements/gui.txt
  fi
  if [ "$1" = "update" ] || [ "$1" = "testPR" ] || [ "$1" = "commit" ]; then
    # build the Qt GUI, do not run libsecp256k1 test
    sudo -u joinmarket ./install.sh --with-qt --disable-secp-check 
  else
    # build the Qt GUI
    sudo -u joinmarket ./install.sh --with-qt
  fi
  echo "# installed JoinMarket $JMVersion"
}

# updateJoininBox <reset|commit>
function updateJoininBox() {
  cd /home/joinmarket
  if [ "$1" = "reset" ];then
    echo "# Removing the joininbox source code"
    sudo rm -rf /home/joinmarket/joininbox
    echo "# Downloading the latest joininbox source code"
  fi
  # clone repo in case it is not present
  sudo -u joinmarket git clone https://github.com/openoms/joininbox.git \
  /home/joinmarket/joininbox 2>/dev/null
  echo "# Checking the updates in https://github.com/openoms/joininbox"
  # based on https://github.com/apotdevin/thunderhub/blob/master/scripts/updateToLatest.sh
  cd /home/joinmarket/joininbox
  # fetch latest master
  sudo -u joinmarket git fetch
  echo "# Pulling latest changes..."
  sudo -u joinmarket git pull -p
  if [ "$1" = "commit" ]; then
    TAG=$(git describe --tags)
    echo "# Updating to the latest commit in the default branch"
  else
    TAG=$(git tag | sort -V | tail -1)
    # unset $1
    set --
    UPSTREAM=${1:-'@{u}'}
    LOCAL=$(git rev-parse @)
    REMOTE=$(git rev-parse "$UPSTREAM")
    if [ $LOCAL = $REMOTE ]; then
      echo "# You are up-to-date on version" $TAG
      echo
      echo "Press ENTER to return to the menu"
      read key
      exit 0
    fi
  fi
  sudo -u joinmarket git reset --hard $TAG
  echo "# Updated to version" $TAG
  echo "# Copying the scripts in place"
  sudo -u joinmarket cp /home/joinmarket/joininbox/scripts/*.* /home/joinmarket/
  sudo -u joinmarket cp /home/joinmarket/joininbox/scripts/.* /home/joinmarket/ 2>/dev/null
  sudo -u joinmarket chmod +x /home/joinmarket/*.sh
}

function setIRCtoTor() {
  source /home/joinmarket/joinin.conf
  if [ "${runBehindTor}" = "on" ]; then
    sed -i "s/^host = irc.darkscience.net/#host = irc.darkscience.net/g" /home/joinmarket/.joinmarket/joinmarket.cfg
    sed -i "s/^#host = darksci3bfoka7tw.onion/host = darksci3bfoka7tw.onion/g" /home/joinmarket/.joinmarket/joinmarket.cfg
    sed -i "s/^host = irc.hackint.org/#host = irc.hackint.org/g" /home/joinmarket/.joinmarket/joinmarket.cfg
    sed -i "s/^#host = ncwkrwxpq2ikcngxq3dy2xctuheniggtqeibvgofixpzvrwpa77tozqd.onion/host = ncwkrwxpq2ikcngxq3dy2xctuheniggtqeibvgofixpzvrwpa77tozqd.onion/g" /home/joinmarket/.joinmarket/joinmarket.cfg
    sed -i "s/^socks5 = false/#socks5 = false/g" /home/joinmarket/.joinmarket/joinmarket.cfg
    sed -i "s/^#socks5 = true/socks5 = true/g" /home/joinmarket/.joinmarket/joinmarket.cfg
    sed -i "s/^#port = 6667/port = 6667/g" /home/joinmarket/.joinmarket/joinmarket.cfg
    sed -i "s/^#usessl = false/usessl = false/g" /home/joinmarket/.joinmarket/joinmarket.cfg
    echo "# Edited the joinmarket.cfg to communicate over Tor only."
  else
    echo "# Tor is not active, will communicate with IRC servers via clearnet"
  fi
}

function generateJMconfig() {
  if [ ! -f "/home/joinmarket/.joinmarket/joinmarket.cfg" ] ; then
    echo "# Generating joinmarket.cfg with default settings"
    echo
    . /home/joinmarket/joinmarket-clientserver/jmvenv/bin/activate &&\
    cd /home/joinmarket/joinmarket-clientserver/scripts/
    python wallet-tool.py generate --datadir=/home/joinmarket/.joinmarket
  else
    echo "# The joinmarket.cfg is present"
    echo
  fi
  setIRCtoTor
  # set strict permission to joinmarket.cfg
  sudo chmod 600 /home/joinmarket/.joinmarket/joinmarket.cfg || exit 1
 }

#backupJMconf
function backupJMconf() {
  if [ -f "/home/joinmarket/.joinmarket/joinmarket.cfg" ] ; then
    now=$(date +"%Y_%m_%d_%H%M%S")
    echo "# Moving the joinmarket.cfg to the filename joinmarket.cfg.backup$now"
    mv /home/joinmarket/.joinmarket/joinmarket.cfg \
    /home/joinmarket/.joinmarket/joinmarket.cfg.backup$now
    echo
  else
    echo "# The joinmarket.cfg is not present"
    echo
  fi
}

# updateTor
function updateTor() {
  # as in https://2019.www.torproject.org/docs/debian#source
  # https://github.com/rootzoll/raspiblitz/blob/82e0d6c3714ce1b2878780c4bdef72a6417f71c7/home.admin/config.scripts/internet.tor.sh#L493
  echo "# Adding tor-nightly-master to sources.list"
  torSourceListAvailable=$(sudo cat /etc/apt/sources.list | grep -c \
  'tor-nightly-master')
  echo "torSourceListAvailable=${torSourceListAvailable}"  
  if [ ${torSourceListAvailable} -eq 0 ]; then
    echo "Adding TOR sources ..."
    if [ "${baseImage}" = "raspbian" ]||[ "${baseImage}" = "buster" ]||[ "${baseImage}" = "dietpi" ]; then
      distro="buster"
    elif [ "${baseImage}" = "bionic" ]; then
      distro="bionic"
    elif [ "${baseImage}" = "focal" ]; then
      distro="focal"
    fi
    echo "
deb https://deb.torproject.org/torproject.org tor-nightly-master-$distro main
deb-src https://deb.torproject.org/torproject.org tor-nightly-master-$distro main" \
    | sudo tee -a  /etc/apt/sources.list
  fi
  echo "# Running apt update"
  sudo apt update
  source /home/joinmarket/joinin.conf
  if [ ${cpu} = "x86_64" ]; then
    echo "# CPU is x86_64 - updating to the latest alpha binary"
    sudo apt install -y tor
    echo "# Restarting the tor.service "
    sudo systemctl restart tor
  else
    echo "# Install the dependencies for building from source"
    sudo apt install -y build-essential fakeroot devscripts
    sudo apt build-dep -y tor deb.torproject.org-keyring
    rm -rf $HOME//download/debian-packages
    mkdir -p $HOME/download/debian-packages
    cd $HOME/download/debian-packages || exit 1
    echo "# Building Tor from the source code ..."
    apt source tor
    cd tor-* || exit 1
    debuild -rfakeroot -uc -us
    cd .. || exit 1
    echo "# Stopping the tor.service before updating"
    sudo systemctl stop tor
    echo "# Update ..."
    sudo dpkg -i tor_*.deb
    echo "# Starting the tor.service "
    sudo systemctl start tor
    echo "# Installed $(tor --version)"
  fi
}
