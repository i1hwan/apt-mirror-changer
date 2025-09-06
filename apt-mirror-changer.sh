#!/bin/bash

set -e  # Exit on any error
trap 'echo "스크립트가 중단되었습니다. 백업 파일을 확인하세요: $BACKUP_FILE"' ERR

# Ubuntu APT Mirror Changer Script
# ===================================
# Compatible with Ubuntu 20.04 to 25.xx
#
# 특징:
# - 일반 저장소는 선택한 미러 서버 사용
# - 보안 저장소(security)는 항상 공식 security.ubuntu.com 서버 사용

# --- Configuration ---
# Format: "TAG" "Description" "URL"
# Easily add or modify mirrors here
MIRRORS=(
    "KAIST"     "KAIST (ftp.kaist.ac.kr)"          "http://ftp.kaist.ac.kr/ubuntu/"
    "KAKAO"     "Kakao (mirror.kakao.com)"          "http://mirror.kakao.com/ubuntu/"
    "ORIGINAL"  "Ubuntu Official (archive.ubuntu.com)"   "http://archive.ubuntu.com/ubuntu/"
)
# --- End of Configuration ---


# --- Global Variables ---
TARGET_FILE=""
SOURCES_FORMAT="" # "deb" for sources.list, "deb822" for .sources
BACKUP_FILE=""
UBUNTU_CODENAME=$(lsb_release -cs 2>/dev/null || echo "jammy") # Default to jammy if not found
UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "0")
TEST_FILES=("dists/${UBUNTU_CODENAME}/InRelease") # Use InRelease for testing
MIRRORS_WITH_SPEED=()
FASTEST_MIRROR_TAG=""
FASTEST_MIRROR_URL=""
FASTEST_SPEED=0
SCRIPT_START_TIME=$(date +%s)
INTERACTIVE=true
DEBUG=false


# --- Functions ---

# Function to check for debug mode and print messages
debug() {
    if [ "$DEBUG" = true ]; then
        echo >&2 "$*"
    fi
}

# Function to check for root privileges
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "오류: 이 스크립트는 root 권한으로 실행해야 합니다. 'sudo'를 사용해주세요."
        exit 1
    fi
}

# Function to check for dependencies
check_deps() {
    for cmd in whiptail wget lsb_release; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "'$cmd'가 설치되어 있지 않습니다. 스크립트 실행에 필수적인 패키지입니다."
            if [ "$EUID" -eq 0 ]; then
                apt update && apt install -y whiptail wget lsb-release
            else
                echo "root 권한으로 'sudo apt install -y whiptail wget lsb-release'를 실행해주세요."
                exit 1
            fi
        fi
    done
}

# Function to detect which sources file is being used
detect_sources_file() {
    if [ -f "/etc/apt/sources.list.d/ubuntu.sources" ]; then
        TARGET_FILE="/etc/apt/sources.list.d/ubuntu.sources"
        SOURCES_FORMAT="deb822"
    elif [ -f "/etc/apt/sources.list" ]; then
        TARGET_FILE="/etc/apt/sources.list"
        SOURCES_FORMAT="deb"
    else
        if [ "$INTERACTIVE" = true ]; then
            whiptail --title "오류" --msgbox "APT 소스 파일을 찾을 수 없습니다. (/etc/apt/sources.list 또는 /etc/apt/sources.list.d/ubuntu.sources)\n스크립트를 종료합니다." 10 70
        else
            echo "오류: APT 소스 파일을 찾을 수 없습니다."
        fi
        exit 1
    fi
    BACKUP_FILE="${TARGET_FILE}.bak"
    if [ ! -r "$TARGET_FILE" ]; then
        if [ "$INTERACTIVE" = true ]; then
            whiptail --title "오류" --msgbox "소스 파일을 읽을 수 없습니다. 권한을 확인해주세요." 8 50
        else
            echo "오류: 소스 파일을 읽을 수 없습니다."
        fi
        exit 1
    fi
}

# Function to back up the original sources file
backup_file() {
    if [ ! -f "$BACKUP_FILE" ]; then
        cp -a "$TARGET_FILE" "$BACKUP_FILE"
        if [ "$INTERACTIVE" = true ]; then
            whiptail --title "백업" --infobox "기존 설정 파일을 '${BACKUP_FILE}' (으)로 백업했습니다." 8 50
            sleep 2
        else
            echo "백업: 기존 설정 파일을 '${BACKUP_FILE}'으로 백업했습니다."
        fi
    fi
}

# Arguments: $1 = Mirror URL
measure_speed() {
    local mirror_url=$1
    local test_file="${TEST_FILES[0]}"
    local full_url="${mirror_url}${test_file}"

    debug "파일 크기 확인 중: $full_url"
    # Try to get file size
    local file_size=$( { wget --spider --timeout=3 --server-response "$full_url" 2>&1 | grep -i "Content-Length" | awk '{print $2}' | tr -d '
' ; } || echo "" )
    if [ -z "$file_size" ]; then
        file_size=0
    fi
    debug "파일 크기: $file_size bytes"

    debug "wget 명령어: wget --timeout=3 --tries=2 -v -O /dev/null $full_url"
        local start=$(date +%s%3N)
        if wget --timeout=3 --tries=2 -O /dev/null "$full_url" > /dev/null 2>&1 || true; then
        local end=$(date +%s%3N)
        local duration_ms=$((end - start))
        local duration=$((duration_ms / 1000))
    debug "다운로드 성공, 시간: $duration_ms ms ($duration 초)"
        if [ $duration_ms -gt 0 ] && [ "$file_size" -gt 0 ]; then
            local speed=$((file_size * 1000 / duration_ms))  # Bytes per second
            debug "계산된 속도: $speed B/s"
            echo "$speed"
        else
            debug "파일 크기 없음 또는 시간 0으로 속도 계산 실패"
            echo "fail"
        fi
    else
    debug "다운로드 실패"
        echo "fail"
    fi
}

# Function to format speed in human-readable format (B/s -> KB/s or MB/s)
format_speed() {
    local speed_bps=$1
    if [ "$speed_bps" -lt 1024 ]; then
        echo "${speed_bps} B/s"
    elif [ "$speed_bps" -lt 1048576 ]; then
        echo "$((speed_bps / 1024)) KB/s"
    else
        echo "$((speed_bps / 1048576)) MB/s"
    fi
}

# Function to test all mirrors and find the fastest one
measure_all_speeds() {
    local mirror_count=$(( ${#MIRRORS[@]} / 3 ))
    local current_mirror=0
    local step=0

    if [ "$INTERACTIVE" = true ]; then
        # NOTE: 파이프(|)를 사용하면 for 루프가 서브셸에서 실행되어 FASTEST_SPEED 등의 변수값이 부모 쉘에 반영되지 않음.
        # 이를 피하려고 whiptail을 별도 프로세스에 붙인 출력 FD(3)로 연결하여 루프는 현재 쉘에서 실행되도록 함.
        # whiptail gauge에서 사용자가 ESC/취소를 누르면 파이프가 닫히면서 이후 쓰기에서 SIGPIPE(141) 발생 -> set -e 로 인해 스크립트 전체 종료
        # 방지: SIGPIPE 무시, 해당 상황 감지 후 루프 조기 종료
        gauge_closed=0
        trap 'gauge_closed=1' PIPE
        # set -e 임시 해제
        set +e
        exec 3> >(whiptail --title "미러 서버 속도 측정" --gauge "각 미러 서버의 다운로드 속도를 측정하고 있습니다... (취소하려면 ESC)" 8 78 0)
        for i in "${!MIRRORS[@]}"; do
            if (( i % 3 != 0 )); then
                continue
            fi

            if [ "$gauge_closed" -eq 1 ]; then
                debug "사용자가 게이지를 취소했습니다. 남은 미러는 건너뜁니다."
                break
            fi

            tag=${MIRRORS[i]}
            desc=${MIRRORS[i+1]}
            url=${MIRRORS[i+2]}
            full_url="${url}${TEST_FILES[0]}"

            debug "루프 시작: i=$i, tag=$tag, desc=$desc"
            debug "속도 테스트 시작: $(date)"
            debug "테스트 중: $desc - URL: $full_url"

            # 진행률 (현재까지 완료한 개수 기준)
            local percent=$(( current_mirror * 100 / mirror_count ))
            if [ "$gauge_closed" -eq 0 ]; then
                {
                    echo "$percent"
                    echo "XXX"
                    echo "테스트 중: $desc"
                    echo "XXX"
                } >&3 || true
            fi

            speed=$(measure_speed "$url")
            debug "결과: $desc - $speed"
            if [ "$speed" = "fail" ]; then
                MIRRORS_WITH_SPEED+=("$tag" "$desc (실패)")
                debug "MIRRORS_WITH_SPEED 추가: $tag $desc (실패)"
                gauge_msg="테스트 중: $desc\n결과: 실패"
            else
                formatted_speed=$(format_speed "$speed")
                MIRRORS_WITH_SPEED+=("$tag" "$desc ($formatted_speed)")
                debug "MIRRORS_WITH_SPEED 추가: $tag $desc ($formatted_speed)"
                gauge_msg="테스트 중: $desc\n결과: $formatted_speed"
                if [ "$speed" -gt "$FASTEST_SPEED" ]; then
                    FASTEST_SPEED=$speed
                    FASTEST_MIRROR_TAG=$tag
                    FASTEST_MIRROR_URL=$url
                    debug "FASTEST_SPEED 업데이트: $FASTEST_SPEED, tag=$tag"
                fi
            fi

            # 상태 업데이트 (현재 항목 완료 후 % 갱신)
            ((current_mirror++))
            percent=$(( current_mirror * 100 / mirror_count ))
            if [ "$gauge_closed" -eq 0 ]; then
                {
                    echo "$percent"
                    echo "XXX"
                    echo "$gauge_msg"
                    echo "XXX"
                } >&3 || true
            fi
            debug "루프 끝: i=$i, current_mirror=$current_mirror"
        done
        # 100%로 마무리 (취소 안된 경우)
        if [ "$gauge_closed" -eq 0 ]; then
            {
                echo 100
                echo "XXX"
                echo "완료"
                echo "XXX"
            } >&3 || true
        fi
        # FD 닫기 -> whiptail 종료
        exec 3>&-
        # set -e 복구
        set -e
        trap - PIPE
    else
        echo "속도 테스트 시작: $(date)"
        echo "미러 서버 속도 측정 중..."
        for i in "${!MIRRORS[@]}"; do
            if (( i % 3 == 0 )); then
                tag=${MIRRORS[i]}
                desc=${MIRRORS[i+1]}
                url=${MIRRORS[i+2]}
                full_url="${url}${TEST_FILES[0]}"

                echo "루프 시작: i=$i, tag=$tag, desc=$desc"
                echo "테스트 중: $desc - URL: $full_url"
                speed=$(measure_speed "$url")
                echo "결과: $desc - $speed"
                if [ "$speed" = "fail" ]; then
                    MIRRORS_WITH_SPEED+=("$tag" "$desc (실패)")
                    echo "MIRRORS_WITH_SPEED 추가: $tag $desc (실패)"
                else
                    formatted_speed=$(format_speed "$speed")
                    MIRRORS_WITH_SPEED+=("$tag" "$desc ($formatted_speed)")
                    echo "MIRRORS_WITH_SPEED 추가: $tag $desc ($formatted_speed)"
                    if [ "$speed" -gt "$FASTEST_SPEED" ]; then
                        FASTEST_SPEED=$speed
                        FASTEST_MIRROR_TAG=$tag
                        FASTEST_MIRROR_URL=$url
                        echo "FASTEST_SPEED 업데이트: $FASTEST_SPEED, tag=$tag"
                    fi
                fi
                echo "루프 끝: i=$i"
            fi
        done
    fi

    debug "속도 테스트 완료. 가장 빠른 속도: $FASTEST_SPEED"
    debug "미러 목록: ${MIRRORS_WITH_SPEED[@]}"

    if [ "$FASTEST_SPEED" -eq 0 ]; then
        if [ "$INTERACTIVE" = true ]; then
            whiptail --title "경고" --msgbox "모든 미러 서버의 속도를 측정할 수 없습니다. 네트워크 연결을 확인하거나, 방화벽 설정을 점검해주세요. 수동 선택으로 진행합니다." 10 70
        else
            echo "경고: 모든 미러 서버의 속도를 측정할 수 없습니다."
        fi
    fi
}


# Function to change the mirror URL
# Arguments: $1 = Mirror Name, $2 = Mirror URL
change_mirror() {
    local mirror_desc=$1
    local mirror_url=$2

    if [ "$INTERACTIVE" = true ]; then
        whiptail --title "미러 변경 중" --infobox "'${mirror_desc}' 서버로 변경을 시도합니다..." 8 50
        sleep 1
    else
        echo "미러 변경 중: '${mirror_desc}' 서버로 변경을 시도합니다..."
    fi

    if [ "$SOURCES_FORMAT" == "deb822" ]; then
        sed -i -e '0,/^URIs:/s|^URIs: .*|URIs: '"${mirror_url}"'|' \
               -e '0,/^Suites:/s|^Suites: .*|Suites: '"${UBUNTU_CODENAME}"' '"${UBUNTU_CODENAME}"'-updates '"${UBUNTU_CODENAME}"'-backports|' \
               "$TARGET_FILE"
    else
        debug "변경 전 sources.list 내용:"
        debug "$(cat "$TARGET_FILE" | head -10)"
        
        # security 관련 줄을 제외하고 변경 (security.ubuntu.com 또는 -security가 있는 줄)
        sed -i -E '/(-security|security\.ubuntu\.com)/!s|^deb\s+(https?://)([^/]+)(/ubuntu/?)?|deb '"${mirror_url}"'|g' "$TARGET_FILE"
        
        debug "변경 후 sources.list 내용:"
        debug "$(cat "$TARGET_FILE" | head -10)"
    fi

    if [ $? -eq 0 ]; then
        if [ "$INTERACTIVE" = true ]; then
            whiptail --title "성공" --msgbox "소스 파일의 미러 주소를 성공적으로 변경했습니다. 이제 변경 사항을 검증합니다." 8 60
        else
            echo "성공: 소스 파일의 미러 주소를 변경했습니다."
        fi
        verify_changes "$mirror_url"
    else
        if [ "$INTERACTIVE" = true ]; then
            whiptail --title "오류" --msgbox "파일 수정 중 오류가 발생했습니다. 변경 사항이 적용되지 않았습니다. 백업 파일을 확인해주세요." 8 60
        else
            echo "오류: 파일 수정 중 오류가 발생했습니다."
        fi
        exit 1
    fi
}

# Function to verify changes by checking mirror URL in apt sources
# Arguments: $1 = Mirror URL
verify_changes() {
    local mirror_url="$1"
    if [ "$INTERACTIVE" = true ]; then
        whiptail --title "변경 사항 검증" --infobox "APT 소스에서 미러 URL을 확인합니다. 잠시 기다려주세요..." 8 70
    else
        echo "변경 사항 검증: APT 소스에서 미러 URL을 확인합니다..."
    fi

    # Check if apt update would use the correct mirror
    local apt_output
    apt_output=$(apt update --print-uris 2>/dev/null | head -50)
    debug "apt update --print-uris 출력:"
    debug "$apt_output"
    
    # 일반 저장소는 지정된 미러로, 보안 저장소는 security.ubuntu.com으로 설정되었는지 확인
    local mirror_found=0
    local security_found=0
    
    # 선택한 미러가 일반 저장소에 적용되었는지 확인
    if echo "$apt_output" | grep -q "$mirror_url"; then
        mirror_found=1
        debug "미러 URL 확인됨: $mirror_url"
    fi
    
    # 보안 저장소가 적절하게 설정되었는지 확인
    # Ubuntu 버전에 따라 security.ubuntu.com 또는 -security 패턴 확인
    if echo "$apt_output" | grep -q "security.ubuntu.com\|security\|${UBUNTU_CODENAME}-security"; then
        security_found=1
        debug "보안 저장소 확인됨"
    fi
    
    if [ $mirror_found -eq 1 ] && [ $security_found -eq 1 ]; then
        if [ "$INTERACTIVE" = true ]; then
            whiptail --title "검증 성공" --msgbox "APT 서버 주소가 성공적으로 변경되었습니다!\n- 일반 저장소: $mirror_url\n- 보안 저장소: security.ubuntu.com" 10 60
            exit 0
        else
            echo "검증 성공: APT 소스에서 지정한 미러 URL을 확인했습니다."
            echo "- 일반 저장소: $mirror_url"
            echo "- 보안 저장소: security.ubuntu.com"
            exit 0
        fi
    else
        local error_message=""
        if [ $mirror_found -eq 0 ]; then
            error_message="${error_message}일반 저장소 미러 URL이 올바르게 변경되지 않았습니다.\n"
        fi
        if [ $security_found -eq 0 ]; then
            error_message="${error_message}보안 저장소 URL이 올바르게 설정되지 않았습니다.\n"
        fi
        
        if [ "$INTERACTIVE" = true ]; then
            whiptail --title "검증 실패" --yesno "APT 소스 변경이 올바르게 적용되지 않았습니다:\n${error_message}\n백업 파일로 자동 복원하시겠습니까?" 12 70
            if [ $? -eq 0 ]; then
                if [ -f "$BACKUP_FILE" ]; then
                    cp -a "$BACKUP_FILE" "$TARGET_FILE"
                    whiptail --title "복원 완료" --msgbox "백업 파일로부터 설정을 성공적으로 복원했습니다." 8 60
                else
                    whiptail --title "복원 실패" --msgbox "백업 파일을 찾을 수 없습니다." 8 50
                fi
            fi
        else
            echo "검증 실패:"
            echo -e "$error_message"
            if [ -f "$BACKUP_FILE" ]; then
                cp -a "$BACKUP_FILE" "$TARGET_FILE"
                echo "백업 파일로부터 설정을 복원했습니다."
            fi
            exit 1
        fi
    fi
}

# Function to restore from backup
restore_from_backup() {
    if [ -f "$BACKUP_FILE" ]; then
        if (whiptail --title "복원 확인" --yesno "'${BACKUP_FILE}' 파일로 설정을 복원하시겠습니까?" 8 60); then
            cp -a "$BACKUP_FILE" "$TARGET_FILE"
            whiptail --title "복원 완료" --msgbox "백업 파일로부터 설정을 성공적으로 복원했습니다." 8 60
        fi
    else
        whiptail --title "오류" --msgbox "백업 파일('${BACKUP_FILE}')을 찾을 수 없습니다." 8 60
    fi
}


# --- Main Logic ---
main() {
    # Parse options
    while [[ $# -gt 0 ]]; do
        case $1 in
            --no-interactive)
                INTERACTIVE=false
                shift
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            *)
                echo "사용법: $0 [--no-interactive]"
                exit 1
                ;;
        esac
    done

    # Check Ubuntu version compatibility
    if ! [[ "$UBUNTU_VERSION" =~ ^(20|21|22|23|24|25)\. ]]; then
        if [ "$INTERACTIVE" = true ]; then
            whiptail --title "호환성 오류" --msgbox "이 스크립트는 Ubuntu 20.04 이상을 지원합니다. 현재 버전: $UBUNTU_VERSION\n스크립트를 종료합니다." 10 70
        else
            echo "호환성 오류: 이 스크립트는 Ubuntu 20.04 이상을 지원합니다. 현재 버전: $UBUNTU_VERSION"
        fi
        exit 1
    fi

    check_root
    check_deps
    detect_sources_file
    backup_file
    measure_all_speeds

    if [ "$INTERACTIVE" = false ]; then
        if [ "$FASTEST_SPEED" -gt 0 ]; then
            change_mirror "$FASTEST_MIRROR_TAG 서버" "$FASTEST_MIRROR_URL"
            echo "가장 빠른 미러로 변경 완료."
        else
            echo "사용 가능한 미러가 없습니다."
            exit 1
        fi
        exit 0
    fi

    while true; do
        # Build menu options dynamically
        menu_options=("FASTEST")
        if [ "$FASTEST_SPEED" -eq 0 ]; then
            menu_options+=("속도 측정 실패 - 수동 선택")
        else
            menu_options+=("가장 빠른 미러로 자동 변경 ($(format_speed $FASTEST_SPEED))")
        fi

        # Add mirrors from MIRRORS_WITH_SPEED if available, otherwise from MIRRORS
        if [ ${#MIRRORS_WITH_SPEED[@]} -gt 0 ]; then
            for ((i=0; i<${#MIRRORS_WITH_SPEED[@]}; i+=2)); do
                tag="${MIRRORS_WITH_SPEED[i]}"
                desc="${MIRRORS_WITH_SPEED[i+1]}"
                menu_options+=("$tag" "$desc")
            done
        else
            for ((i=0; i<${#MIRRORS[@]}; i+=3)); do
                tag="${MIRRORS[i]}"
                desc="${MIRRORS[i+1]}"
                menu_options+=("$tag" "$desc (측정 실패)")
            done
        fi

        menu_options+=("RESTORE" "백업 파일(.bak)에서 복원")

        CHOICE=$(whiptail --title "Ubuntu APT 미러 변경 스크립트 v2" --menu "변경할 미러 서버를 선택하세요." 20 78 12 \
        "${menu_options[@]}" \
        3>&1 1>&2 2>&3)

        exit_status=$?
        if [ $exit_status = 0 ]; then
            case "$CHOICE" in
                FASTEST)
                    if [ "$FASTEST_SPEED" -gt 0 ]; then
                        change_mirror "$FASTEST_MIRROR_TAG 서버" "$FASTEST_MIRROR_URL"
                    else
                        whiptail --title "경고" --msgbox "속도 측정이 실패하여 가장 빠른 미러를 찾을 수 없습니다. 수동으로 미러를 선택해주세요." 8 60
                    fi
                    ;;
                RESTORE)
                    restore_from_backup
                    ;;
                *)
                    # Find URL for the chosen mirror tag
                    for i in "${!MIRRORS[@]}"; do
                         if [[ "${MIRRORS[i]}" == "$CHOICE" ]]; then
                            mirror_desc=${MIRRORS[i+1]}
                            mirror_url=${MIRRORS[i+2]}
                            change_mirror "$mirror_desc" "$mirror_url"
                            break
                        fi
                    done
                    ;;
            esac
        else
            local end_time=$(date +%s)
            local duration=$((end_time - SCRIPT_START_TIME))
            whiptail --title "종료" --msgbox "스크립트 작업을 취소했습니다.\n실행 시간: ${duration}초" 8 50
            exit 0
        fi
    done
}

# Run the main function
main