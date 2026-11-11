#!/usr/bin/env bash
# =============================================================================
# fix-nvidia-kali.sh — починка NVIDIA-драйвера на Kali Linux
# Для: GeForce GTX 1660 SUPER, ядро 7.2.x, чёрный экран из-за nouveau.
#
# VER: 3
#
# Возможности:
#   - САМООБНОВЛЕНИЕ: при запуске сверяет себя с GitHub и, если я (автор)
#     обновил скрипт в репозитории, качает новую версию сам. Поэтому на ПК
#     друга всегда вводится ОДНА И ТА ЖЕ команда:
#       wget https://raw.githubusercontent.com/uf0rs/kali-nvidia-fix/master/fix-nvidia-kali.sh && sudo bash fix-nvidia-kali.sh
#   - Чистит сломанную установку драйвера 550 (dpkg error 1, DKMS failed)
#   - Ставит свежий драйвер 620 из репозитория NVIDIA (debian13)
#   - План B: если CDN отдаёт 404 на Packages — качает индекс вручную
#   - Проверяет Secure Boot, блокирует nouveau, убирает лишние ядра
#   - При любой ошибке печатает компактную ДИАГНОСТИКУ (одно фото = всё)
#   - После успеха САМОУДАЛЯЕТСЯ и предлагает перезагрузку
#
# v3: FIX — apt по-русски пишет «Kandidat», а не «Candidate» → весь вывод
#     apt-cache/apt-get теперь под LC_ALL=C (англ.), парсинг работает везде.
# =============================================================================

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; N=$'\033[0m'
ok()   { printf '%s[OK]%s %s\n' "$G" "$N" "$1"; }
info() { printf '%s[..]%s %s\n' "$Y" "$N" "$1"; }
bad()  { printf '%s[!!]%s %s\n' "$R" "$N" "$1"; }

SELF="$(readlink -f "$0")"
SELF_URL="https://raw.githubusercontent.com/uf0rs/kali-nvidia-fix/master/fix-nvidia-kali.sh"
MYVER="3"

if [ "$EUID" -ne 0 ]; then
  bad "Запусти через sudo:  sudo bash $0"
  exit 1
fi

# ---------------- АВТООБНОВЛЕНИЕ с GitHub ----------------
REMOTE_VER=$(wget -q -T 10 -t 1 -O - "$SELF_URL" 2>/dev/null | grep -m1 '^# VER:' | awk '{print $3}')
if [ -n "$REMOTE_VER" ] && [ "$REMOTE_VER" != "$MYVER" ]; then
  info "Найдена новая версия скрипта ($MYVER -> $REMOTE_VER) — обновляюсь..."
  TMPU=$(mktemp)
  if wget -q -T 15 -t 2 -O "$TMPU" "$SELF_URL" 2>/dev/null && grep -q '^# VER:' "$TMPU"; then
    mv -f "$TMPU" "$SELF"
    ok "Обновлён до версии $REMOTE_VER — перезапускаюсь"
    exec bash "$SELF"
  fi
  rm -f "$TMPU"
  info "Обновление не удалось — продолжаю текущей версией"
fi
# подчистка мусорных копий, которые wget создаёт при повторных запусках
rm -f -- "${SELF}".[0-9]* 2>/dev/null || true

# ---------------- компактная диагностика при любой ошибке ----------------
dump_diag() {
  echo "---------- ДИАГНОСТИКА (пришли мне фото этого блока) ----------"
  echo "Ядро: $(uname -r)"
  echo "--- /etc/apt/sources.list.d:"
  ls -l /etc/apt/sources.list.d/ 2>/dev/null
  echo "--- файлы индексов nvidia в кэше apt:"
  ls -la /var/lib/apt/lists/ 2>/dev/null | grep -i -E 'nvidia|download' || echo "(нет — индекс NVIDIA не лежит в кэше)"
  echo "--- apt-cache policy nvidia-driver:"
  LC_ALL=C apt-cache policy nvidia-driver 2>/dev/null
  echo "--- dkms status:"
  dkms status 2>/dev/null
  echo "--- ошибки последнего apt update:"
  grep -iE 'err|404|E:' /tmp/nvidia-fix-apt.log 2>/dev/null | tail -8
  echo "---------------------------------------------------------------"
}

echo "============================================================"
echo " NVIDIA Kali fix v$MYVER — шаг 1/7: зачистка"
echo "============================================================"

apt-get purge -y '^nvidia-' '^libnvidia-' xserver-xorg-video-nvidia >/dev/null 2>&1 || true
ok "Пакеты NVIDIA удалены"

apt-get --fix-broken install -y >/dev/null 2>&1 || true
ok "Состояние dpkg приведено в порядок"

rm -f /etc/apt/sources.list.d/*cuda* /etc/apt/sources.list.d/*nvidia*
ok "Старые репозитории NVIDIA удалены (включая мусорное debian12)"

rm -rf /var/lib/apt/lists/*
ok "Кэш индексов apt очищен"

echo
echo "=== 2/7: свежий репозиторий NVIDIA (debian13, новый ключ) ==="
echo 'deb [trusted=yes] https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/ /' > /etc/apt/sources.list.d/cuda.list
ok "Репозиторий добавлен"

info "Обновление индексов (несколько минут, не прерывай)..."
LC_ALL=C apt-get update 2>&1 | tee /tmp/nvidia-fix-apt.log >/dev/null || info "apt update выдал ошибки — пробуем план B..."

CAND=$(LC_ALL=C apt-cache policy nvidia-driver 2>/dev/null | awk '/Candidate:/{print $2}')

# --- План B: если CDN отдал 404 на Packages — качаем индекс вручную ---
if [ -z "$CAND" ] || [ "${CAND%%.*}" = "550" ]; then
  info "Индекс NVIDIA не подтянулся. План B: ручная загрузка Packages.gz..."
  TMP=$(mktemp -d)
  if wget -q -T 20 -t 2 -O "$TMP/P.gz" https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/Packages.gz; then
    gunzip -c "$TMP/P.gz" > /var/lib/apt/lists/developer.download.nvidia.com_compute_cuda_repos_debian13_x86_64_Packages
    cp /var/lib/apt/lists/developer.download.nvidia.com_compute_cuda_repos_debian13_x86_64_Packages \
       /var/lib/apt/lists/developer.download.nvidia.com_compute_cuda_repos_debian13_x86_64_Packages_amd64 2>/dev/null || true
    rm -rf "$TMP"
    ok "Индекс загружен вручную"
    LC_ALL=C apt-get update >/dev/null 2>&1 || true
  else
    bad "Не удалось скачать Packages.gz — проверь интернет"
    dump_diag
    exit 1
  fi
  CAND=$(LC_ALL=C apt-cache policy nvidia-driver 2>/dev/null | awk '/Candidate:/{print $2}')
fi

if [ -z "$CAND" ] || [ "${CAND%%.*}" = "550" ]; then
  bad "apt не видит свежий драйвер (кандидат: ${CAND:-нет})."
  dump_diag
  exit 1
fi
ok "Свежий драйвер виден: $CAND"

echo
echo "=== 3/7: Secure Boot ==="
DEBIAN_FRONTEND=noninteractive apt-get install -y mokutil >/dev/null 2>&1 || true
if command -v mokutil >/dev/null 2>&1; then
  if mokutil --sb-state 2>/dev/null | grep -qiE 'enabled|включ'; then
    bad "Secure Boot ВКЛЮЧЁН — модуль NVIDIA не загрузится."
    bad "Отключи его в BIOS (Boot -> Secure Boot -> Disabled) и запусти скрипт снова."
    exit 1
  fi
  ok "Secure Boot: disabled"
else
  info "mokutil недоступен — проверку Secure Boot пропускаем"
fi

echo
echo "=== 4/7: заголовки нового ядра + чистка старых ядер ==="
NEWK_PKG=$(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | grep -v -- '-cloud\|-rt\|-dbg' | sort -V | tail -1)
if [ -z "$NEWK_PKG" ]; then
  bad "Не нашёл установленные ядра"
  dump_diag
  exit 1
fi
NEWK_VER=${NEWK_PKG#linux-image-}
info "Новое ядро: $NEWK_VER"
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "linux-headers-$NEWK_VER"; then
  bad "Не удалось поставить linux-headers-$NEWK_VER"
  dump_diag
  exit 1
fi
ok "Заголовки ядра установлены (под них соберётся DKMS-модуль)"

for p in $(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null); do
  if [ "$p" != "$NEWK_PKG" ]; then
    if DEBIAN_FRONTEND=noninteractive apt-get remove -y "$p" >/dev/null 2>&1; then
      ok "Старое ядро удалено: $p"
    fi
  fi
done

echo
echo "=== 5/7: блокировка nouveau + параметры GRUB ==="
printf 'blacklist nouveau\noptions nouveau modeset=0\n' > /etc/modprobe.d/blacklist-nouveau.conf
ok "nouveau заблеклистен"

update-initramfs -u >/dev/null 2>&1 && ok "initramfs обновлён" || info "update-initramfs: мелкие предупреждения допустимы"

if ! grep -q 'nvidia_drm.modeset=1' /etc/default/grub; then
  sed -i 's/quiet splash/quiet splash nvidia_drm.modeset=1/' /etc/default/grub
fi
update-grub >/dev/null 2>&1 && ok "GRUB обновлён"

echo
echo "=== 6/7: установка драйвера NVIDIA (качает сотни МБ, не прерывай) ==="
INSTALLED=0
if DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get install -y --allow-unauthenticated nvidia-driver; then
  INSTALLED=1
else
  info "Первая попытка не удалась — чиню зависимости и пробую ещё раз..."
  DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get --fix-broken install -y >/dev/null 2>&1 || true
  if DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get install -y --allow-unauthenticated nvidia-driver; then
    INSTALLED=1
  fi
fi

if [ "$INSTALLED" = "1" ]; then
  ok "Драйвер NVIDIA установлен и модуль собран!"
else
  bad "Установка не удалась. Последние ошибки сборки DKMS:"
  find /var/lib/dkms -name make.log -exec tail -n 20 {} \; 2>/dev/null
  echo
  dkms status 2>/dev/null
  echo
  dump_diag
  bad "Скрипт НЕ удалился — исправлю и дам перезапустить ТУ ЖЕ команду."
  exit 1
fi

echo
echo "=== 7/7: финиш ==="
ok "Всё готово. Скрипт удаляет сам себя с этого ПК..."
rm -f -- "$SELF" && ok "Скрипт удалён"

echo
echo "После перезагрузки проверь драйвер командой:  nvidia-smi"
printf "Перезагрузить ПК сейчас? [Y/n]: "
read -r ANSWER || ANSWER=y
case "$ANSWER" in
  n|N|no|нет|НЕТ) echo "Ок — перезагружи вручную:  sudo reboot" ;;
  *) ok "Перезагрузка..."; sleep 2; reboot ;;
esac
