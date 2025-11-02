#!/usr/bin/env bash
# github-tool.sh -- GitHub için çok amaçlı araç menüsü
# Özellikler: Repo Kopyalama, Toplu Star/Unstar, Toplu Takip
# GÜNCELLEME: URL normalleştirmesi eklendi (owner/repo formatını otomatik algılama)
# GÜNCELLEME 2: Main_menu'deki syntax hatası düzeltildi.
set -euo pipefail

# --- Renk Kodları ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'
C_WHITE='\033[1;37m'

# --- Gereksinimler ---
for cmd in git curl jq; do
  if ! command -v $cmd >/dev/null 2>&1; then
    echo -e "${C_RED}Eksik: $cmd. Termux'ta kurmak için: pkg install $cmd${C_RESET}"
    exit 1
  fi
done

# --- Token Fonksiyonları ---
TOKEN_FILE="token.txt"
TOKENS=()

# token.txt dosyasından token'ları yükler
load_tokens() {
  echo -e "${C_CYAN}Token dosyası okunuyor: $TOKEN_FILE${C_RESET}"
  TOKENS=() # Diziyi temizle
  if [[ ! -f "$TOKEN_FILE" ]]; then
    echo -e "${C_RED}Hata: $TOKEN_FILE dosyası bulunamadı.${C_RESET}"
    echo -e "${C_YELLOW}Toplu işlemler için script ile aynı dizine $TOKEN_FILE oluşturun.${C_RESET}"
    return 1
  fi
  
  # Dosyayı oku, yorumları (#) ve boş satırları atla
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ ! "$line" =~ ^\s*# && -n "$line" ]]; then
      TOKENS+=("$line")
    fi
  done < "$TOKEN_FILE"

  if [[ ${#TOKENS[@]} -eq 0 ]]; then
    echo -e "${C_RED}Hata: $TOKEN_FILE içinde hiç geçerli token bulunamadı.${C_RESET}"
    return 1
  fi

  echo -e "${C_GREEN}Başarıyla ${#TOKENS[@]} adet token yüklendi.${C_RESET}"
  return 0
}

# --- API Çağrı Fonksiyonları (Rate Limit için 5sn bekleme ile) ---

# GitHub API'ye PUT isteği (Star, Follow)
api_put() {
  local token=$1
  local endpoint=$2
  local user_index=$3

  echo -en "${C_CYAN} -> [Hesap ${user_index}]${C_RESET} ${endpoint} için istek gönderiliyor... "
  
  # -H "Content-Length: 0" boş PUT isteği için gereklidir
  HTTP_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X PUT \
    -H "Authorization: token $token" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Content-Length: 0" \
    "https://api.github.com/$endpoint")

  if [[ "$HTTP_STATUS" -eq 204 ]]; then
    echo -e "${C_GREEN}Başarılı (Kod: $HTTP_STATUS)${C_RESET}"
    return 0
  else
    echo -e "${C_RED}Başarısız! (Kod: $HTTP_STATUS)${C_RESET}"
    return 1
  fi
}

# GitHub API'ye DELETE isteği (Unstar, Unfollow)
api_delete() {
  local token=$1
  local endpoint=$2
  local user_index=$3

  echo -en "${C_CYAN} -> [Hesap ${user_index}]${C_RESET} ${endpoint} için istek gönderiliyor... "
  
  HTTP_STATUS=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X DELETE \
    -H "Authorization: token $token" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/$endpoint")

  if [[ "$HTTP_STATUS" -eq 204 ]]; then
    echo -e "${C_GREEN}Başarılı (Kod: $HTTP_STATUS)${C_RESET}"
    return 0
  else
    echo -e "${C_RED}Başarısız! (Kod: $HTTP_STATUS)${C_RESET}"
    return 1
  fi
}


# ===============================================
# === ÖZELLİK 1: REPO KOPYALAMA (GELİŞMİŞ) ===
# ===============================================
func_repo_copy() {
  echo -e "${C_WHITE}--- 1. GitHub Repo Kopyalama Aracı ---${C_RESET}"
  
  local GHTOKEN SRC_INPUT TARGET_REPO TARGET_DESC TOPICS IS_PRIVATE="n"
  
  echo -n "Repo oluşturma yetkisine sahip GitHub Token'ı girin (gözükmeyecek): "
  read -s GHTOKEN
  echo
  if [[ -z "$GHTOKEN" ]]; then
    echo -e "${C_RED}Token gerekli. Menüye dönülüyor.${C_RESET}"; sleep 2; return
  fi

  read -p "Kaynak repo (owner/repo veya URL): " SRC_INPUT
  read -p "Hedef repoda olması istenen isim: " TARGET_REPO
  if [[ -z "$SRC_INPUT" || -z "$TARGET_REPO" ]]; then
    echo -e "${C_RED}Kaynak ve Hedef repo ismi gerekli. Menüye dönülüyor.${C_RESET}"; sleep 2; return
  fi
  read -p "Hedef repo açıklaması (opsiyonel): " TARGET_DESC
  read -p "Hedef repo private (gizli) olsun mu? (y/n) [n]: " IS_PRIVATE_INPUT
  IS_PRIVATE=${IS_PRIVATE_INPUT:-n}
  read -p "Repo konuları (virgülle ayırın, opsiyonel): " TOPICS

  # URL normalleştirme
  local SRC_REPO
  if [[ "$SRC_INPUT" =~ github.com/ ]]; then
    SRC_REPO=$(echo "$SRC_INPUT" | sed -E 's#https?://(www\.)?github.com/##; s#\.git$##; s#/$##')
  else
    SRC_REPO="$SRC_INPUT"
  fi

  echo "Kullanıcı bilgisi çekiliyor..."
  local API_USER USERNAME
  API_USER=$(curl -sS -H "Authorization: token $GHTOKEN" https://api.github.com/user)
  USERNAME=$(echo "$API_USER" | jq -r .login)
  if [[ "$USERNAME" == "null" || -z "$USERNAME" ]]; then
    echo -e "${C_RED}Token ile kullanıcı alınamadı. Token'ı kontrol et.${C_RESET}"; sleep 2; return
  fi
  echo "Token sahibi: ${C_GREEN}$USERNAME${C_RESET}"

  local TMPDIR
  TMPDIR="$(mktemp -d /data/data/com.termux/files/home/tmp-import-XXXX)"
  trap 'echo -e "${C_YELLOW}Temizlik yapılıyor...${C_RESET}"; rm -rf "$TMPDIR"; trap - EXIT' EXIT

  echo "Kaynak repo kontrol ediliyor: $SRC_REPO"
  if ! curl -sSf -H "Authorization: token $GHTOKEN" "https://api.github.com/repos/$SRC_REPO" >/dev/null; then
    echo -e "${C_RED}Kaynak repo bulunamadı veya erişilemiyor: $SRC_REPO${C_RESET}"; sleep 2; return
  fi

  local PRIV_BOOL="false"
  if [[ "${IS_PRIVATE,,}" == "y" ]]; then
    PRIV_BOOL="true"
    echo "Hedef repo oluşturuluyor: $USERNAME/$TARGET_REPO (Gizli & MIT lisanslı)"
  else
    echo "Hedef repo oluşturuluyor: $USERNAME/$TARGET_REPO (Public & MIT lisanslı)"
  fi

  local CREATE_PAYLOAD CREATE_RESP
  CREATE_PAYLOAD=$(jq -n --arg name "$TARGET_REPO" --arg desc "$TARGET_DESC" --argjson priv $PRIV_BOOL \
    '{name:$name, description:$desc, private:$priv, auto_init:false, license_template:"mit"}')
  CREATE_RESP=$(curl -sS -H "Authorization: token $GHTOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    -d "$CREATE_PAYLOAD" https://api.github.com/user/repos)

  if ! echo "$CREATE_RESP" | jq -e '.id' >/dev/null 2>&1; then
    local ERRMSG=$(echo "$CREATE_RESP" | jq -r '.message // "unknown error"')
    echo -e "${C_RED}Repo oluşturulurken hata: $ERRMSG${C_RESET}"; sleep 2; return
  fi
  echo -e "${C_GREEN}Hedef repo başarıyla oluşturuldu.${C_RESET}"

  if [[ -n "$TOPICS" ]]; then
    echo "Konular ekleniyor: $TOPICS"
    local TOPICS_PAYLOAD
    TOPICS_PAYLOAD=$(echo "$TOPICS" | jq -R 'split(",") | map(select(length > 0) | ltrimstr(" ") | rtrimstr(" "))' | jq -n '{names: inputs}')
    curl -sS -X PUT -H "Authorization: token $GHTOKEN" \
      -H "Accept: application/vnd.github.v3+json" \
      -d "$TOPICS_PAYLOAD" "https://api.github.com/repos/$USERNAME/$TARGET_REPO/topics" >/dev/null
  fi

  echo "Kaynak repo klonlanıyor (snapshot)…"
  cd "$TMPDIR"
  git clone --depth 1 "https://$GHTOKEN@github.com/$SRC_REPO.git" src >/dev/null 2>&1 || { echo "${C_RED}Clone başarısız${C_RESET}"; return; }

  echo "Hedef repo klonlanıyor (içindeki MIT lisans dahil)..."
  git clone "https://$GHTOKEN@github.com/$USERNAME/$TARGET_REPO.git" tgt >/dev/null 2>&1

  echo "Dosyalar kopyalanıyor..."
  shopt -s dotglob
  cd src
  cd ../tgt
  local HAS_LICENSE=false
  if [[ -f LICENSE ]] || [[ -f LICENSE.md ]] || [[ -f LICENSE.txt ]]; then
    HAS_LICENSE=true
  fi
  cd ../src

  for f in * .[^.]*; do
    if [[ "$f" == "." || "$f" == ".." || "$f" == ".git" ]]; then continue; fi
    if $HAS_LICENSE && [[ "${f,,}" =~ ^license ]]; then
      continue
    fi
    cp -r "$f" "$TMPDIR/tgt/" || { echo "${C_RED}Kopyalama hatası: $f${C_RESET}"; return; }
  done
  shopt -u dotglob

  cd "$TMPDIR/tgt"
  local DEFAULT_BRANCH
  DEFAULT_BRANCH=$(git rev-parse --abbrev-ref HEAD || echo "main")
  git add --all
  if git diff --cached --quiet; then
    echo -e "${C_YELLOW}Değişiklik yok — push atlanıyor.${C_RESET}"
  else
    git commit -m "Import: dosyalar kopyalandı from $SRC_REPO" >/dev/null
    git push origin "$DEFAULT_BRANCH" >/dev/null 2>&1
    echo -e "${C_GREEN}Dosyalar pushlandı -> https://github.com/$USERNAME/$TARGET_REPO${C_RESET}"
  fi
  
  trap - EXIT
  rm -rf "$TMPDIR"
  echo -e "${C_GREEN}Repo Kopyalama İşlemi Tamamlandı.${C_RESET}"
  read -p "Devam etmek için Enter'a basın..."
}


# ===============================================
# === ÖZELLİK 2: TOPLU REPO STAR'LAMA ===
# ===============================================
func_repo_star() {
  echo -e "${C_WHITE}--- 2. Toplu Repo Star'lama Aracı ---${C_RESET}"
  
  if ! load_tokens; then
    sleep 2; return
  fi

  local total_tokens=${#TOKENS[@]}
  read -p "Star atılacak hedef repo (örn: owner/repo veya URL): " TARGET_REPO
  if [[ -z "$TARGET_REPO" ]]; then
    echo -e "${C_RED}Hedef repo gerekli. Menüye dönülüyor.${C_RESET}"; sleep 2; return
  fi
  
  # URL Normalleştirme
  if [[ "$TARGET_REPO" =~ github.com/ ]]; then
    echo -e "${C_YELLOW} -> URL algılandı, 'owner/repo' formatına çevriliyor...${C_RESET}"
    TARGET_REPO=$(echo "$TARGET_REPO" | sed -E 's#https?://(www\.)?github.com/##; s#\.git$##; s#/$##')
    echo -e "${C_CYAN} -> Düzeltilmiş hedef: $TARGET_REPO${C_RESET}"
  fi
  
  read -p "Kaç hesaptan star atılsın? (Toplam: $total_tokens) [Tümü]: " COUNT_INPUT
  local count_to_star=${COUNT_INPUT:-$total_tokens}

  if ! [[ "$count_to_star" =~ ^[0-9]+$ ]] || [[ "$count_to_star" -gt "$total_tokens" ]]; then
    echo -e "${C_RED}Geçersiz sayı. $total_tokens veya daha az olmalı.${C_RESET}"
    count_to_star=$total_tokens
    echo -e "${C_YELLOW}Tüm hesaplar ($total_tokens) kullanılacak.${C_RESET}"
  fi

  echo -e "${C_YELLOW}Başlatılıyor: $TARGET_REPO repo'su $count_to_star hesap ile star'lanacak...${C_RESET}"
  
  local success_count=0
  local fail_count=0
  
  for (( i=0; i<$count_to_star; i++ )); do
    local token="${TOKENS[$i]}"
    local user_index=$((i+1))
    
    if api_put "$token" "user/starred/$TARGET_REPO" "$user_index"; then
      ((success_count++))
    else
      ((fail_count++))
    fi
    
    if [[ $i -lt $((count_to_star - 1)) ]]; then
      echo "5 saniye bekleniyor..."
      sleep 5
    fi
  done

  echo -e "${C_GREEN}İşlem Tamamlandı.${C_RESET}"
  echo -e "Başarılı: ${C_GREEN}$success_count${C_RESET} | Başarısız: ${C_RED}$fail_count${C_RESET}"
  read -p "Devam etmek için Enter'a basın..."
}


# ===============================================
# === ÖZELLİK 3: TOPLU REPO UN-STAR'LAMA ===
# ===============================================
func_repo_unstar() {
  echo -e "${C_WHITE}--- 3. Toplu Repo Un-Star'lama Aracı ---${C_RESET}"
  
  if ! load_tokens; then
    sleep 2; return
  fi

  local total_tokens=${#TOKENS[@]}
  read -p "Un-star yapılacak hedef repo (örn: owner/repo veya URL): " TARGET_REPO
  if [[ -z "$TARGET_REPO" ]]; then
    echo -e "${C_RED}Hedef repo gerekli. Menüye dönülüyor.${C_RESET}"; sleep 2; return
  fi
  
  # URL Normalleştirme
  if [[ "$TARGET_REPO" =~ github.com/ ]]; then
    echo -e "${C_YELLOW} -> URL algılandı, 'owner/repo' formatına çevriliyor...${C_RESET}"
    TARGET_REPO=$(echo "$TARGET_REPO" | sed -E 's#https?://(www\.)?github.com/##; s#\.git$##; s#/$##')
    echo -e "${C_CYAN} -> Düzeltilmiş hedef: $TARGET_REPO${C_RESET}"
  fi
  
  read -p "Kaç hesaptan un-star yapılsın? (Toplam: $total_tokens) [Tümü]: " COUNT_INPUT
  local count_to_unstar=${COUNT_INPUT:-$total_tokens}

  if ! [[ "$count_to_unstar" =~ ^[0-9]+$ ]] || [[ "$count_to_unstar" -gt "$total_tokens" ]]; then
    echo -e "${C_RED}Geçersiz sayı. $total_tokens veya daha az olmalı.${C_RESET}"
    count_to_unstar=$total_tokens
    echo -e "${C_YELLOW}Tüm hesaplar ($total_tokens) kullanılacak.${C_RESET}"
  fi

  echo -e "${C_YELLOW}Başlatılıyor: $TARGET_REPO repo'su $count_to_unstar hesaptan un-star yapılacak...${C_RESET}"
  
  local success_count=0
  local fail_count=0
  
  for (( i=0; i<$count_to_unstar; i++ )); do
    local token="${TOKENS[$i]}"
    local user_index=$((i+1))
    
    if api_delete "$token" "user/starred/$TARGET_REPO" "$user_index"; then
      ((success_count++))
    else
      ((fail_count++))
    fi
    
    if [[ $i -lt $((count_to_unstar - 1)) ]]; then
      echo "5 saniye bekleniyor..."
      sleep 5
    fi
  done

  echo -e "${C_GREEN}İşlem Tamamlandı.${C_RESET}"
  echo -e "Başarılı: ${C_GREEN}$success_count${C_RESET} | Başarısız: ${C_RED}$fail_count${C_RESET}"
  read -p "Devam etmek için Enter'a basın..."
}

# ===============================================
# === ÖZELLİK 4: TOPLU KULLANICI TAKİP ETME ===
# ===============================================
func_user_follow() {
  echo -e "${C_WHITE}--- 4. Toplu Kullanıcı Takip Etme Aracı ---${C_RESET}"
  
  if ! load_tokens; then
    sleep 2; return
  fi

  local total_tokens=${#TOKENS[@]}
  read -p "Takip edilecek kullanıcı adı (örn: torvalds veya URL): " TARGET_USER
  if [[ -z "$TARGET_USER" ]]; then
    echo -e "${C_RED}Kullanıcı adı gerekli. Menüye dönülüyor.${C_RESET}"; sleep 2; return
  fi
  
  # URL Normalleştirme (Kullanıcı adı için)
  if [[ "$TARGET_USER" =~ github.com/ ]]; then
    echo -e "${C_YELLOW} -> URL algılandı, 'kullanıcı' formatına çevriliyor...${C_RESET}"
    # Sadece /'dan sonraki ilk kısmı al (kullanıcı adı)
    TARGET_USER=$(echo "$TARGET_USER" | sed -E 's#https?://(www\.)?github.com/##' | cut -d'/' -f1)
    echo -e "${C_CYAN} -> Düzeltilmiş hedef: $TARGET_USER${C_RESET}"
  fi
  
  read -p "Kaç hesaptan takip edilsin? (Toplam: $total_tokens) [Tümü]: " COUNT_INPUT
  local count_to_follow=${COUNT_INPUT:-$total_tokens}

  if ! [[ "$count_to_follow" =~ ^[0-9]+$ ]] || [[ "$count_to_follow" -gt "$total_tokens" ]]; then
    echo -e "${C_RED}Geçersiz sayı. $total_tokens veya daha az olmalı.${C_RESET}"
    count_to_follow=$total_tokens
    echo -e "${C_YELLOW}Tüm hesaplar ($total_tokens) kullanılacak.${C_RESET}"
  fi

  echo -e "${C_YELLOW}Başlatılıyor: $TARGET_USER kullanıcısı $count_to_follow hesap ile takip edilecek...${C_RESET}"
  
  local success_count=0
  local fail_count=0
  
  for (( i=0; i<$count_to_follow; i++ )); do
    local token="${TOKENS[$i]}"
    local user_index=$((i+1))
    
    if api_put "$token" "user/following/$TARGET_USER" "$user_index"; then
      ((success_count++))
    else
      ((fail_count++))
    fi
    
    if [[ $i -lt $((count_to_follow - 1)) ]]; then
      echo "5 saniye bekleniyor..."
      sleep 5
    fi
  done

  echo -e "${C_GREEN}İşlem Tamamlandı.${C_RESET}"
  echo -e "Başarılı: ${C_GREEN}$success_count${C_RESET} | Başarısız: ${C_RED}$fail_count${C_RESET}"
  read -p "Devam etmek için Enter'a basın..."
}

# ===============================================
# === ANA MENÜ (DÜZELTİLDİ) ===
# ===============================================
main_menu() {
  while true; do
    clear
    echo -e "${C_WHITE}=======================================${C_RESET}"
    echo -e "${C_WHITE}    GitHub Çok Amaçlı Araç Menüsü${C_RESET}"
    echo -e "${C_WHITE}=======================================${C_RESET}"
    echo -e "İşlemler ${C_CYAN}$TOKEN_FILE${C_RESET} dosyasındaki tokenlar ile yapılır."
    echo
    echo -e " ${C_YELLOW}1.${C_RESET} Repo Kopyala (İçe Aktar)"
    echo -e " ${C_YELLOW}2.${C_RESET} Toplu Repo Star'la"
    echo -e " ${C_YELLOW}3.${C_RESET} Toplu Repo Un-Star'la"
    echo -e " ${C_YELLOW}4.${C_RESET} Toplu Kullanıcı Takip Et (Ek Özellik)"
    echo
    echo -e " ${C_RED}q.${C_RESET} Çıkış"
    echo
    read -p "Seçiminiz [1-4, q]: " CHOICE

    case $CHOICE in
      1)
        func_repo_copy
        ;;
      2)
        func_repo_star
        ;;
      3)
        func_repo_unstar
        ;;
      4)
        func_user_follow
        ;;
      q|Q)
        echo -e "${C_CYAN}Görüşmek üzere!${C_RESET}"
        exit 0
        ;;
      *)
        echo -e "${C_RED}Geçersiz seçim. Lütfen tekrar deneyin.${C_RESET}"
        sleep 2
        ;;
    esac
  done
}

# Script'i başlat
main_menu
