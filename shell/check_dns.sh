#!/bin/bas/h
# 描述：脚本用来检查/etc/resolv.conf中dns server，设定超时时间为1s
# curl检查超时时间超过1s换下一个DNS，检查文件中所有仍超过1s，告警通知
# 预设定脚本每隔3分钟执行一次
#
HOSTNAME=$(grep "^id:" /etc/salt/minion |awk '{print $2}')
FDNS="/etc/resolv.conf"
LOGDIR=$(cd $(dirname $0);pwd)

script_name="${0##*/}"
cron_file="/var/spool/cron/root"

FREX="([0-9]{1,3}[\.]){3}[0-9]{1,3}"
NUMS=$(grep -v "^#" $FDNS |awk '{print $2}' |egrep $FREX|wc -l)

NETWORK=$(ip a|grep UP|grep -v DOWN|grep -v 'lo:'|awk '{print $2}'|cut -d':' -f1)
IP=$(ip a|grep "$NETWORK"|tail -1|cut -d'/' -f1|awk '{print $2}')
#

# check whether command "bc" is exist or not
result=$(which bc 2>/dev/null)
if [[ "$result" = "" ]];then
yum -y install bc
fi
# dig command is provided by "bind-utils"
if [[ "$(which dig 2>/dev/null)" = "" ]];then
yum -y install bind-utils
fi
#
# crontab添加PATH环境变量，重启crond服务.
# 暂不启用,经测试,在cron中执行有问题.
cron_path(){
  PATHRESULT=$(crontab -l|grep -o PATH)
  if [[ "$PATHRESULT" = "" ]];then
    PATH=$(echo $PATH)
    sed -i "1 i\PATH=$PATH" $cron_file
    /etc/init.d/crond restart
  fi
}
# cronpath
# 公共DNS组 ,国内
PUBLICDNS="119.29.29.29
182.254.116.116"
# 国外
#PUBLICDNS="8.8.4.4
#208.67.222.222"
# 检测本地DNS前,先判断是否有公共DNS，如有,delete
check_dns(){
  tDNS=$(grep -v "^#" $FDNS|awk '{print $2}'  |egrep $FREX|wc -l)
  if [ $tDNS -eq 1 ];then
    alerted "only public DNS" "only public DNS"
    exit 2
  fi
  for CDNS in $PUBLICDNS; do
    RS=$(sed -n "/$CDNS/p" $FDNS)
    if [[ "$RS" != "" ]]; then
      sed -i "/$CDNS/d" $FDNS
    fi
  done
}
check_dns
# 更换/etc/resolv.conf中DNS SERVER 顺序
change_dns(){
    sed -i "/$DNS/d" $FDNS
    echo "nameserver $DNS" >>$FDNS
    /data/app/apache2/bin/httpd -k restart
    NUM=$(($NUM + 1))
}
# 邮件告警，personal.php中修改邮件接收人，可多人
alerted(){
python /data/app/scripts/cron/sendmail.py "$@"
}
# 记录log
logit(){
  echo "$@" >>$LOGDIR/dns_result.txt
}
#
# check resovl.conf is null
if [ $NUMS -eq 0 ];then
    echo "nameserver 119.29.29.29" >>$FDNS
    alerted "$HOSTNAME nameserver null" "nameserver is null:$HOSTNAME-$IP"
    exit 2
fi

TIMEOUT=1
OPTS="-o /dev/null -s -w %{time_namelookup}\n"
FURLS="http://www.baidu.com
http://www.qq.com
http://www.taobao.com"
DATE="date +%Y%m%d-%H:%M:%S"
# 判断公共DNS是否可用
valid_dns(){
  for PDNS in $PUBLICDNS;do
    RESULT=$(dig @$PDNS ${FURL#*//} |grep status|awk '{print $6}'|cut -d, -f1)
    if [[ "$RESULT" = "NOERROR" ]];then
      sed -i "1 i\nameserver $PDNS" $FDNS
      exit 0
    else
      alerted "public dns fail" "$HOSTNAME:$IP-$PDNS"
    fi
  done
}
# 检查当地地区DNS是否可用
for FURL in $FURLS;do
NUM=1
  while [ $NUM -le $NUMS ]
  do
    DNS=$(grep -v "^#" $FDNS|awk '{print $2}'  |egrep $FREX|head -1)
    RESULT=$(dig @$DNS ${FURL#*//} |grep status|awk '{print $6}'|cut -d, -f1)
    if [[ "$RESULT" = "NOERROR" ]];then
      FTIME=`curl $OPTS $FURL`
      if [ $(echo "$FTIME<$TIMEOUT"|bc) -eq 1 ];then
        break
      else
        if [ $NUM -ne $NUMS ];then
          logit "* $($DATE):retry $NUM time,$FURL $DNS timeout: $FTIME"
          change_dns
          sleep 1
        else
          logit "* $($DATE):retry $NUM time,$FURL $DNS timeout: $FTIME"
          logit "* $($DATE): $FURL all dns server time more than $TIMEOUT"
      #    alerted "dns timeout:$HOSTNAME" "dns timeout:$HOSTNAME-$IP"
          exit 1
        fi
      fi
    else
      if [ $NUM -ne $NUMS ];then
        logit "* $($DATE):retry $NUM time,$FURL $DNS [$RESULT]"
        change_dns
        sleep 5
      else
        logit "* $($DATE):retry $NUM time,$FURL $DNS [$RESULT]"
        logit "* "
        logit "* retry $NUM times,no dns server could be reached"
        logit "* "
        time_log="$LOGDIR/time.log"
	tim=$(date +%s)
	[ ! -f $time_log ] && echo $tim >>$time_log && exit 1
	if [ $(wc -l $time_log|awk '{print $1}') -lt 4 ];then
	    echo $tim >>$time_log
	    exit 1
	fi
	tim3=$(tail -n2 $time_log|head -n1)
	tim5=$(tail -n4 $time_log|head -n1)
	echo $tim >> $time_log
	echo $tim3 $tim5
	echo $tim
	if [ $(($tim - $tim3)) -le 121 ];then
	    alerted "dns fail:$HOSTNAME" "dns fail:$HOSTNAME-$IP"
	fi
        if [ $((expr $tim - $tim5)) -le 241 ];then
            sed -i "/$script_name/s/^/#/g" $cron_file
            sed -i "/check_dns_second.sh/s/#//g"  $cron_file
        fi
        exit 2
      fi
    fi
  done
done
