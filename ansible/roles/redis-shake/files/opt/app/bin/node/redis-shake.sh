REDIS_SHAKE_DIR="/data/redis-shake/"
REDIS_SHAKE_CONF=$REDIS_SHAKE_DIR/redis-shake.conf

initNode() {
  local caddyPath="/data/caddy"
  mkdir -p $REDIS_SHAKE_DIR/{,logs} $caddyPath
  chown -R shake.svc $REDIS_SHAKE_DIR
  chown -R caddy.svc $caddyPath
  touch $REDIS_SHAKE_CONF
  local htmlFile=/data/index.html; [ -e "$htmlFile" ] || ln -s /opt/app/conf/caddy/index.html $htmlFile
  _initNode
}

start() {
  isNodeInitialized || execute initNode
  configure && _start
}


getRedisMasterList() {
  local getName="$(echo "$1" | tr 'a-z' 'A-Z')" host port authOpt retCode result
  [[  " SOURCE TARGET " == *" $getName "* ]] || return 1
  local redis_type="$(eval echo '$'${getName}_TYPE)"
  local address="$(eval echo '$'${getName}_ADDRESS)"
  local password="$(eval echo '$'${getName}_PASSWORD)"
  [[ -n "$password" ]] && authOpt="-a '$password'"
  if [[  "$redis_type" == "standalone" ]]; then
    echo $address
  elif [[  "$redis_type" == "cluster" ]]; then
    for host in $(echo $address | sed "s/;/ /g"); do
      port="6379"
      retCode=0
      [[ -n "${host#*:}" ]] && port="${host#*:}"
      result=$(runRedisCmd -h ${host%:*} -p $port $authOpt cluster nodes || retCode=$?)
      if [[ $retCode == 0 ]]; then 
        echo "$result" | awk -F "[ @ ]+" '$4~/master/{print $2}' | paste -sd ";"
        return 0
      fi
    done
    return $retCode
  fi
}

configure() {
  rotate $REDIS_SHAKE_CONF
  cat /opt/app/conf/redis-shake/redis-shake.conf > $REDIS_SHAKE_CONF
  echo "source.address = $(getRedisMasterList "SOURCE")" >> $REDIS_SHAKE_CONF
  echo "target.address = $(getRedisMasterList "TARGET")" >> $REDIS_SHAKE_CONF
}

revive() {
  checkSvc redis-shake || configure
  _revive $@
}


measure() {
  local measureInfo
  measureInfo="$(curl -s http://127.0.0.1:9320/metric )"
  {
    echo $measureInfo | jq ".[].PullCmdCountTotal" | awk '{sum+=$1} END {print "PullCmd:"sum}'
    echo $measureInfo | jq ".[].PushCmdCountTotal" | awk '{sum+=$1} END {print "PushCmd:"sum}'
    echo $measureInfo | jq ".[].SuccessCmdCountTotal" | awk '{sum+=$1} END {print "SuccessCmd:"sum}'
    echo $measureInfo | jq ".[].FailCmdCountTotal" | awk '{sum+=$1} END {print "FailCmd:"sum}'
    echo $measureInfo | jq ".[].ProcessingCmdCount" | awk '{sum+=$1} END {print "ProcessingCmd:"sum}'
    echo $measureInfo | jq ".[].Status" | awk 'BEGIN{ status="incr" } $0!~/incr/{status="full"} END {print "Status:"status}'
  } | jq -R 'split(":")|{(.[0]):.[1]}' | jq -sc add
}


destroy() {
  echo
}


runRedisCmd() {
  local not_error="getUserList aclManage measure runRedisCmd"
  local redisIp redisPort=6379 maxTime=5 retCode=0 passwd authOpt="" result redisCli
  while :
    do
    if [[ "$1" == "--timeout" ]]; then
      maxTime=$2 && shift 2
    elif [[ "$1" == "--ip" || "$1" == "-h" ]]; then
      redisIp=$2 && shift 2
    elif [[ "$1" == "--port" || "$1" == "-p" ]]; then
      redisPort=$2 && shift 2
    elif [[ "$1" == "--password" || "$1" == "-a" ]]; then
      passwd=$2 && shift 2
    else
      break
    fi
  done
  [ -n "$passwd" ] && authOpt="--no-auth-warning -a $passwd"
  redisCli="/opt/redis/current/redis-cli $authOpt"
  echo "timeout --preserve-status ${maxTime}s $redisCli -h $redisIp -p $redisPort $@ 2>&1"
  result="$(timeout --preserve-status ${maxTime}s $redisCli -h $redisIp -p $redisPort $@ 2>&1)" || retCode=$?
  if [ "$retCode" != 0 ] || [[ " $not_error " != *" $cmd "* && "$result" == *ERR* ]]; then
    log "ERROR failed to run redis command '$@' ($retCode): $result." && retCode=$REDIS_COMMAND_EXECUTE_FAIL_ERR
  else
    echo "$result"
  fi
  return $retCode
}

reload() {
  isNodeInitialized || return 0
  execute restart
}

check(){
  [[ "${REVIVE_ENABLED:-"true"}" == "true" ]] || return 0
  _check
}

