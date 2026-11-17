#!/usr/bin/env bash
# PUDLA: check of the main server from OUTSIDE Timeweb (GitHub Actions), task x-hosting-standby, 17.11.2026.
# The check that lives on the test server falls together with it when all of Timeweb is down (17.11, ~50 min):
# this one runs elsewhere. Once a minute it asks https://pudla.app/api/health; if the app does not answer
# FAIL checks in a row, a message goes to the service channel; while down, a reminder every REMIND minutes;
# when it answers again, «снова работает».
#
# Runs for RUN_MIN minutes, then the next scheduled run takes over (the workflow keeps one at a time).
# State (kind fails since alerted last) lives in the file `state` and is committed, so a new run remembers an
# outage that is already reported. Once a week `heartbeat` is committed too: GitHub turns off schedules
# in a repository with no commits for 60 days.
#
# Env: TG_TOKEN (bot token, a secret), TG_CHAT (channel id, a secret), DRY=1 prints instead of sending.
# The logs of a public repository are public: never print the token or the chat id.
set -uo pipefail
export LC_ALL=C.UTF-8

URL=${URL:-https://pudla.app}
FAIL=${FAIL:-5}            # checks in a row (= minutes)
REMIND=${REMIND:-60}       # minutes between reminders
RUN_MIN=${RUN_MIN:-50}
STATE=state
BEAT=heartbeat

tg() {
  [ -n "${DRY:-}" ] && { printf 'TELEGRAM: %s\n' "$1"; return 0; }
  [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ] || { echo "нет TG_TOKEN / TG_CHAT"; return 1; }
  # the token goes to curl through stdin, so it never shows in the log or the process list
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TG_TOKEN" \
    | curl -sS --max-time 30 -K - --form-string "chat_id=$TG_CHAT" --form-string "text=$1" | grep -q '"ok":true'
}
msk() { TZ=MSK-3 date -d "@$1" '+%H:%M %d.%m'; }
mins() { echo $(( ($2 - $1 + 30) / 60 )); }

# prints "ok" or a short reason
probe() {
  local out code
  out=$(curl -sS --max-time 20 -o /tmp/h.json -w '%{http_code}' "$URL/api/health" 2>&1) || { echo "нет ответа"; return; }
  code=${out: -3}
  [ "$code" = 200 ] && grep -q '"ok":true' /tmp/h.json && { echo ok; return; }
  echo "ответ $code"
}

save() { # commit the state when it changed (and the weekly heartbeat)
  git add "$STATE" "$BEAT" 2>/dev/null
  git diff --cached --quiet && return 0
  git -c user.name="pudla-watch" -c user.email="pudla-watch@users.noreply.github.com" commit -qm "$1" \
    && { git pull -q --rebase || true; git push -q || echo "не удалось сохранить состояние"; }
}

# TEST=1 (the «Run workflow» button with «test» on): one message to the channel, to see the token and the chat work
if [ -n "${TEST:-}" ]; then
  r=$(probe)
  tg "🧪 Проверка PUDLA снаружи Timeweb подключена. Сейчас pudla.app: $([ "$r" = ok ] && echo 'открывается' || echo "НЕ открывается ($r)"). Дальше сюда придёт сообщение, только если приложение не откроется 5 минут подряд." \
    && echo "пробное сообщение отправлено" || { echo "пробное сообщение НЕ отправлено"; exit 1; }
  exit 0
fi

kind=ok fails=0 since=0 alerted=0 last=0
[ -f "$STATE" ] && read -r kind fails since alerted last < "$STATE"
[ -f "$BEAT" ] || echo 0 > "$BEAT"

end=$(( $(date +%s) + RUN_MIN * 60 ))
while [ "$(date +%s)" -lt "$end" ]; do
  t0=$(date +%s)
  r=$(probe)
  [ "$r" != ok ] && { sleep 10; r=$(probe); }   # a single lost packet is not an outage
  now=$(date +%s)
  if [ "$r" = ok ]; then
    if [ "$kind" != ok ]; then
      echo "$(date -u +%T) снова отвечает (сбой с $(msk "$since") МСК)"
      [ "$alerted" = 1 ] && tg "✅ PUDLA снова открывается из интернета (проверка снаружи Timeweb). Сбой длился около $(mins "$since" "$now") мин, с $(msk "$since") МСК."
      kind=ok fails=0 since=0 alerted=0 last=0
      echo "$kind $fails $since $alerted $last" > "$STATE"; save "снова работает"
    fi
  else
    [ "$kind" = ok ] && { kind=bad; fails=0; since=$now; alerted=0; }
    fails=$((fails + 1))
    echo "$(date -u +%T) плохо ($fails): $r"
    if [ "$fails" -ge "$FAIL" ]; then
      text="🔴 PUDLA не открывается из интернета с $(msk "$since") МСК ($r). Это проверка снаружи Timeweb: игроки не могут открыть приложение."
      if [ "$alerted" = 0 ]; then
        tg "$text Если лежит весь Timeweb — смотрите их канал Timeweb Cloud Alerts; иначе напишите Claude: «основа не отвечает»." && { alerted=1; last=$now; }
      elif [ $((now - last)) -ge $((REMIND * 60)) ]; then
        tg "$text Всё ещё не работает: $(mins "$since" "$now") мин." && last=$now
      fi
    fi
    old=$(cat "$STATE" 2>/dev/null)
    echo "$kind $fails $since $alerted $last" > "$STATE"
    # commit only when something a new run must know changed: the outage began, or a message was sent
    [ "$old" != "$(cat "$STATE")" ] && { [ "$fails" = 1 ] || [ "$last" = "$now" ]; } && save "сбой: $r"
  fi
  # once a week: a commit, so GitHub keeps the schedule on
  b=$(cat "$BEAT"); [ $((now - b)) -ge 604800 ] && { echo "$now" > "$BEAT"; save "проверка жива"; }
  s=$(( 60 - ($(date +%s) - t0) )); [ "$s" -gt 0 ] && sleep "$s"
done
echo "$(date -u +%T) конец прогона, состояние: $kind $fails"
