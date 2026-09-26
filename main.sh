#!/bin/bash
    
# SCHOOL_ID=        # 学校编号
# STUDENT_ID=       # 学号
# ALERT_QQ=         # 要推送的 QQ
# QMSG_KEY=         # Qmsg 酱推送Key 获取方法：https://qmsg.zendee.cn/user 登录Qmsg控制台即可获取我的KEY，选择并添加可用的Qmsg酱的QQ好友，即可接收到消息推送
# ALERT_THRESHOLD=  # 低电量提醒阈值

body=$(curl -sd "param=%7B%22cmd%22%3A%22getbindroom%22%2C%22account%22%3A%22${STUDENT_ID}%22%7D&customercode=${SCHOOL_ID}&method=getbindroom" "https://xqh5.17wanxiao.com/smartWaterAndElectricityService/SWAEServlet" | jq .body) # 从完美校园获取信息

# --- 替换开始：使用 jq 原生解析，避免 sed 带来的灾难 ---
# 使用 jq 的 fromjson 直接把 body 里的转义 JSON 解析为真正的 JSON，比 sed 安全一万倍
PARSED_JSON=$(echo "$body" | jq -r 'fromjson' 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$PARSED_JSON" ]; then
    echo "❌ 解析失败，API 返回格式可能变了"
    exit 1
fi

# 统一归一化为数组：不管有没有 roomlist，都转成数组处理
ROOM_ARRAY=$(echo "$PARSED_JSON" | jq -c 'if .roomlist then .roomlist else [.] end')
roomAmount=$(echo "$ROOM_ARRAY" | jq 'length')

# 遍历数组
for ((i=0; i<$roomAmount; i++))
do
    # 用 jq 精准提取，并进行默认值处理，防止空数据触发误报
    roomName[$i]=$(echo "$ROOM_ARRAY" | jq -r ".[$i].roomfullname // \"未知房间\"" | sed 's/公寓/宿舍/g')
    roomUse[$i]=$(echo "$ROOM_ARRAY" | jq -r ".[$i].detaillist[0].use // \"0\"")
    roomOdd[$i]=$(echo "$ROOM_ARRAY" | jq -r ".[$i].detaillist[0].odd // \"0\"")
    roomStatusCode[$i]=$(echo "$ROOM_ARRAY" | jq -r ".[$i].detaillist[0].status // \"0\"")
    
    # 判断电量是否为空，如果为空则跳过这个房间，不触发告警
    if [ "$roomOdd[$i]" == "0" ] || [ -z "$roomOdd[$i]" ]; then
        continue
    fi

    # 状态码转换
    if [ "${roomStatusCode[$i]}" -eq 1 ]; then
        roomStatus[$i]="一般送电"
    else
        roomStatus[$i]="一般断电"
    fi
done
# --- 替换结束 ---

# --- 替换消息拼接与判断逻辑 ---
msg="[电费不足提醒]目前与您的学号 ${STUDENT_ID:0:4}****** 绑定的以下房间，剩余电量不足 ${ALERT_THRESHOLD} 度，请及时缴纳电费哦~"
msgFlag=0

for((i=0; i<$roomAmount; i++))
do
    # 过滤掉那些没有取到电量（即空值或 0）的虚假房间
    if [ -z "${roomOdd[$i]}" ] || [ "${roomOdd[$i]}" == "0" ]; then
        continue
    fi

    # 使用 bc 进行浮点数精确比较，避免四舍五入带来的漏报
    IS_LOW=$(echo "${roomOdd[$i]} < ${ALERT_THRESHOLD}" | bc)
    
    if [ "$IS_LOW" -eq 1 ]; then
        msgFlag=1
        msg="$msg 【${roomName[$i]}】剩余${roomOdd[$i]}度电"
    fi
done

# 输出日志（由于 Actions 中输出的日志所有人可见，出于保护隐私目的，这段注释了）
# echo -e "[`date "+%Y-%m-%d %A %H:%M:%S"`] 学号${STUDENT_ID:0:4}****** 共绑定了$roomAmount个房间\n房间\t\t\t已使用\t剩余\t状态"
# for((i=0;i<$roomAmount;i++))
# do
#     echo -e "${roomName[$i]}\t${roomUse[$i]}\t${roomOdd[$i]}\t${roomStatus[$i]}"
# done

QmsgFlag=false  # 是否推送成功标记
i=0
while [ $msgFlag -eq 1 ] && [ "$QmsgFlag" != "true" ] && [ $i -lt 3 ]   # 若第一次推送失败，只重试 2 次
do
    # echo $(echo "向与学号 ${STUDENT_ID:0:4}****** 绑定的QQ号 ${ALERT_QQ:0:3}******** 发送消息：$msg")
    echo $(echo "电费不足，正在通过 Qmsg 酱推送消息 ... ...")
    
    res=$(curl -sd "qq=${ALERT_QQ}&msg=$msg" "https://qmsg.zendee.cn:443/send/${QMSG_KEY}")
    
    QmsgFlag=$(echo $res | jq .success)
    if [ "$QmsgFlag" == "true" ];then   # 输出是否推送成功日志
        echo "发送成功：$res"
    else
        echo "发送失败：$res"
        sleep 3
    fi
    let i++
    if [ $i -eq 3 ];then
        exit 1
    fi
done
exit 0
