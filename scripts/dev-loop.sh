#!/bin/bash
# 开发时开着：Claude 往 .dev/request 写一个任务名（env / build / test / run / probe / stop），
# 这里就跑 scripts/dev/ 里同名的脚本，输出写到 .dev/<任务>.log。Ctrl-C 停。
cd "$(dirname "$0")/.."
mkdir -p .dev
: > .dev/request
echo "Eyeline dev loop — watching .dev/request. Ctrl-C to stop."
while true; do
  if [ -s .dev/request ]; then
    task=$(head -n1 .dev/request | tr -cd 'a-z')
    : > .dev/request
    if [ -f "scripts/dev/$task.sh" ]; then
      echo "▶ $task  $(date +%T)"
      bash "scripts/dev/$task.sh" > ".dev/$task.log" 2>&1
      code=$?
      echo "$task $code $(date +%s)" > .dev/done
      echo "  $task → exit $code"
    else
      echo "unknown task: $task"
    fi
  fi
  sleep 0.5
done
