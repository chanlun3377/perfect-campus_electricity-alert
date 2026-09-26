#!/bin/bash
set -uo pipefail

# ================= 配置区域 =================
# 请把下面这几项替换成你自己的真实值
SCHOOL_ID="你的学校ID"
STUDENT_ID="你的学号"
ALERT_QQ="你的QQ号"
QMSG_KEY="你的Qmsg酱KEY"
ALERT_THRESHOLD=15   # 阈值，单位：度
# ===========================================

# 完美校园接口地址
API_URL="https://xqh5.17wanxiao.com/smartWaterAndElectricityService/SWAEServlet"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 开始查询电量..."

# 1. 请求接口
RAW=$(curl -s --max-time 15 \
  -H "User-Agent: Mozilla/5.0 (Linux; Android 13; 2211133C) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Mobile Safari/537.36" \
  -H "Referer: https://xqh5.17wanxiao.com/" \
  -d "param=%7B%22cmd%22%3A%22getbindroom%22%2C%22account%22%3A%22${STUDENT_ID}%22%7D" \
  -d "customercode=${SCHOOL_ID}" \
  -d "method=getbindroom" \
  "$API_URL")

if [ -z "$RAW" ]; then
    echo "❌ 接口无响应"
    exit 1
fi

# 2. 解析外层 JSON，提取 body 里的内容
PARSED=$(echo "$RAW" | jq -r '.body | fromjson' 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$PARSED" ]; then
    echo "❌ 解析失败，原始返回："
    echo "$RAW" | head -c 500
    exit 1
fi

# 3. 获取房间列表
ROOM_ARRAY=$(echo "$PARSED" | jq -c '.roomlist')
ROOM_COUNT=$(echo "$ROOM_ARRAY" | jq 'length')

if [ "$ROOM_COUNT" -eq 0 ]; then
    echo "⚠️ 没有绑定任何房间，退出。"
    exit 0
fi

msg="[电费不足提醒]目前与您的学号 ${STUDENT_ID:0:4}****** 绑定的以下房间，剩余电量不足 ${ALERT_THRESHOLD} 度，请及时缴纳电费哦~"
msgFlag=0

# 4. 遍历每个房间
for ((i=0; i<$ROOM_COUNT; i++))
do
    ROOM_NAME=$(echo "$ROOM_ARRAY" | jq -r ".[$i].roomfullname // \"未知房间\"" | sed 's/公寓/宿舍/g')
    ROOM_ODD=$(echo "$ROOM_ARRAY" | jq -r ".[$i].detaillist[0].odd // \"\"")
    ROOM_STATUS=$(echo "$ROOM_ARRAY" | jq -r ".[$i].detaillist[0].status // \"0\"")

    # 跳过空数据房间，防止误报
    if [ -z "$ROOM_ODD" ] || [ "$ROOM_ODD" == "null" ]; then
        echo "⚠️ 跳过空数据房间：$ROOM_NAME"
        continue
    fi

    # 用 bc 做浮点数比较，避免四舍五入问题
    IS_LOW=$(echo "$ROOM_ODD < $ALERT_THRESHOLD" | bc)

    STATUS_TEXT="一般送电"
    [ "$ROOM_STATUS" != "1" ] && STATUS_TEXT="一般断电"

    echo "查询到：$ROOM_NAME | 剩余 $ROOM_ODD 度 | $STATUS_TEXT"

    if [ "$IS_LOW" -eq 1 ]; then
        msgFlag=1
        msg="$msg 【${ROOM_NAME}】剩余${ROOM_ODD}度电"
    fi
done

# 5. 判断是否需要推送
if [ "$msgFlag" -eq 1 ]; then
    echo "电费不足，正在通过 Qmsg 酱推送消息 ... ..."
    QMSG_URL="https://qmsg.zendee.cn:443/send/${QMSG_KEY}"
    
    # 重试机制
    for attempt in {1..3}; do
        RESPONSE=$(curl -s -d "qq=${ALERT_QQ}&msg=$msg" "$QMSG_URL")
        SUCCESS=$(echo "$RESPONSE" | jq -r '.success')
        
        if [ "$SUCCESS" == "true" ]; then
            echo "✅ 推送成功！"
            exit 0
        else
            echo "⚠️ 第 $attempt 次推送失败：$RESPONSE"
            sleep 3
        fi
    done
    echo "❌ 推送失败，已达最大重试次数"
    exit 1
else
    echo "✅ 所有房间电量充足，无需告警。"
fi
