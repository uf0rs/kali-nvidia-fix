#!/usr/bin/env bash
# =============================================================================
# fix-nvidia-kali.sh — починка NVIDIA-драйвера на Kali Linux
# Для: GeForce GTX 1660 SUPER, ядро 7.2.x, чёрный экран из-за nouveau.
#
# Что делает:
#   1. Чистит сломанную установку драйвера 550 (dpkg error 1, DKMS failed)
#   2. Добавляет свежий репозиторий NVIDIA (debian13) и ставит драйвер 620
#   3. Проверяет Secure Boot, блокирует nouveau, убирает лишние ядра
#   4. После успеха САМОУДАЛЯЕТСЯ и предлагает перезагрузку
#
# Запуск:  sudo bash fix-nvidia-kali.sh
# =============================================================================

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; N=$'\033[0m'
ok()   { printf '%s[OK]%s %s\n'   "$G" "$N" "$1"; }
info() { printf '%s[..]%s %s\n'   "$Y" "$N" "$1"; }
bad()  { printf '%s[!!]%s %s\n'   "$R" "$N" "$1"; }

SELF="$(readlink -f "$0")"

if [ "$EUID" -ne 0 ]; then
  bad "Запусти через sudo:  sudo bash $0"
  exit 1
fi

echo "============================================================"
echo " NVIDIA Kali fix — шаг 1/7: зачистка сломанной установки"
echo "============================================================"

apt-get purge -y '^nvidia-' '^libnvidia-' xserver-xorg-video-nvidia >/dev/null 2>&1 || true
ok "Пакеты NVIDIA удалены"

rm -f /etc/apt/sources.list.d/*cuda* /etc/apt/sources.list.d/*nvidia*
ok "Старые репозитории NVIDIA удалены (включая мусорное debian12)"

rm -rf /var/lib/apt/lists/*
ok "Кэш индексов apt очищен"

echo
echo "=== 2/7: свежий репозиторий NVIDIA (debian13, новый ключ) ==="
echo 'deb [trusted=yes] https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/ /' > /etc/apt/sources.list.d/cuda.list
ok "Репозиторий добавлен"

info "Обновление индексов (несколько минут, не прерывай)..."
apt-get update >/dev/null 2>&1 || info "apt update выдал ошибки — пробуем план B..."

CAND=$(apt-cache policy nvidia-driver 2>/dev/null | awk '/Candidate:/{print $2}')

# --- План B: если CDN отдал 404 на Packages — качаем индекс вручную ---
if [ -z "$CAND" ] || [ "${CAND%%.*}" = "550" ]; then
  info "Индекс NVIDIA не подтянулся. План B: ручная загрузка Packages.gz..."
  TMP=$(mktemp -d)
  if wget -q -O "$TMP/P.gz" https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/Packages.gz; then
    gunzip -c "$TMP/P.gz" > /var/lib/apt/lists/developer.download.nvidia.com_compute_cuda_repos_debian13_x86_64_Packages
    cp /var/lib/apt/lists/developer.download.nvidia.com_compute_cuda_repos_debian13_x86_64_Packages \
       /var/lib/apt/lists/developer.download.nvidia.com_compute_cuda_repos_debian13_x86_64_Packages_amd64 2>/dev/null || true
    rm -rf "$TMP"
    ok "Индекс загружен вручную"
  else
    bad "Не удалось скачать Packages.gz — проверь интернет и повтори запуск"
    exit 1
  fi
  CAND=$(apt-cache policy nvidia-driver 2>/dev/null | awk '/Candidate:/{print $2}')
fi

if [ -z "$CAND" ] || [ "${CAND%%.*}" = "550" ]; then
  bad "apt не видит свежий драйвер (кандидат: ${CAND:-нет})."
  bad "Выполни и пришли вывод:  apt-cache policy nvidia-driver"
  exit 1
fi
ok "Свежий драйвер виден: $CAND"

echo
echo "=== 3/7: Secure Boot ==="
DEBIAN_FRONTEND=noninteractive apt-get install -y mokutil >/dev/null 2>&1 || true
if command -v mokutil >/dev/null 2>&1; then
  if mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
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
  bad "Не нашёл установленные ядра — не от чего плясать, останавливаюсь"
  exit 1
fi
NEWK_VER=${NEWK_PKG#linux-image-}
info "Новое ядро: $NEWK_VER"
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "linux-headers-$NEWK_VER"; then
  bad "Не удалось поставить linux-headers-$NEWK_VER"
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
if DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-unauthenticated nvidia-driver; then
  ok "Драйвер NVIDIA установлен и модуль собран!"
else
  bad "Установка упала. Последние строки логов сборки:"
  find /var/lib/dkms -name make.log -exec tail -n 20 {} \; 2>/dev/null
  bad "Пришли этот вывод — разберёмся. Скрипт НЕ удалился, чтобы можно было повторить."
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
