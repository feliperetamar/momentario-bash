#!/bin/bash
# Test script for date validation in get_file_date function

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

pass=0
fail=0

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((pass++)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((fail++)); }

# Create test directory
TEST_DIR="/tmp/test_date_validation_$$"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Source the function from organizar_fotos.sh
# We'll extract just the get_file_date function for testing
cat > test_get_file_date.sh << 'EOFFUNCTION'
get_file_date() {
    local file="$1"
    local date_str=""
    local current_year=$(date +%Y)
    
    # 1. Intentar con exiv2 (DateTimeOriginal) - Más rápido
    date_str=$(exiv2 -g DateTimeOriginal -Pv "$file" 2>/dev/null | head -n1)
    if [[ "$date_str" =~ ^[0-9]{4}:[0-9]{2}:[0-9]{2} ]]; then
        # Usar parameter expansion en lugar de sed/cut
        echo "${date_str:0:4}-${date_str:5:2}-${date_str:8:2}"
        return
    fi

    # 2. Intentar con exiv2 (DateCreated - para algunos RAWs/XMP)
    date_str=$(exiv2 -g DateCreated -Pv "$file" 2>/dev/null | head -n1)
    if [[ "$date_str" =~ ^[0-9]{4}:[0-9]{2}:[0-9]{2} ]]; then
        echo "${date_str:0:4}-${date_str:5:2}-${date_str:8:2}"
        return
    fi

    # 3. Fallback a mediainfo (útil para videos si exiv2 falla)
    date_str=$(mediainfo --Output="General;%Encoded_Date%" "$file" 2>/dev/null)
    if [[ "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
        echo "${date_str:0:10}"
        return
    fi

    # 4. Fallback al nombre del archivo
    local filename=$(basename "$file")
    
    # Pattern 1: YYYY-MM-DD or YYYYMMDD
    if [[ "$filename" =~ ([0-9]{4})[-_]?([0-9]{2})[-_]?([0-9]{2}) ]]; then
        local year="${BASH_REMATCH[1]}"
        local month="${BASH_REMATCH[2]}"
        local day="${BASH_REMATCH[3]}"
        
        # Force base-10 interpretation by removing leading zeros
        year=$((10#$year))
        month=$((10#$month))
        day=$((10#$day))
        
        # Validate year (1900 to current year)
        if [[ "$year" -ge 1900 && "$year" -le "$current_year" ]]; then
            # Validate month (01-12)
            if [[ "$month" -ge 1 && "$month" -le 12 ]]; then
                # Validate day (01-31) - basic validation
                if [[ "$day" -ge 1 && "$day" -le 31 ]]; then
                    # Format with leading zeros
                    printf "%04d-%02d-%02d\n" "$year" "$month" "$day"
                    return
                fi
            fi
        fi
    fi
    
    # Pattern 2: DD-MM-YYYY or DDMMYYYY
    if [[ "$filename" =~ ([0-9]{2})[-_]?([0-9]{2})[-_]?([0-9]{4}) ]]; then
        local day="${BASH_REMATCH[1]}"
        local month="${BASH_REMATCH[2]}"
        local year="${BASH_REMATCH[3]}"
        
        # Force base-10 interpretation by removing leading zeros
        year=$((10#$year))
        month=$((10#$month))
        day=$((10#$day))
        
        # Validate year (1900 to current year)
        if [[ "$year" -ge 1900 && "$year" -le "$current_year" ]]; then
            # Validate month (01-12)
            if [[ "$month" -ge 1 && "$month" -le 12 ]]; then
                # Validate day (01-31) - basic validation
                if [[ "$day" -ge 1 && "$day" -le 31 ]]; then
                    # Format with leading zeros
                    printf "%04d-%02d-%02d\n" "$year" "$month" "$day"
                    return
                fi
            fi
        fi
    fi

    # 5. Último recurso: fecha de modificación del archivo
    date -r "$file" "+%Y-%m-%d"
}
EOFFUNCTION

source test_get_file_date.sh

echo "=== Testing Date Validation ==="
echo ""

# Test 1: Invalid pattern from issue (should fallback to file date)
touch -t 202301150930 "E5038AAE8968891AD7C5AF4EC3C22575E01978527D8856D9C3ACD942.JPG"
result=$(get_file_date "E5038AAE8968891AD7C5AF4EC3C22575E01978527D8856D9C3ACD942.JPG")
if [[ "$result" == "2023-01-15" ]]; then
    log_pass "Test 1: Invalid pattern uses file date (got $result)"
else
    log_fail "Test 1: Expected 2023-01-15, got $result"
fi

# Test 2: Valid date pattern YYYY-MM-DD
touch "2023-05-15_photo.jpg"
result=$(get_file_date "2023-05-15_photo.jpg")
if [[ "$result" == "2023-05-15" ]]; then
    log_pass "Test 2: Valid YYYY-MM-DD pattern (got $result)"
else
    log_fail "Test 2: Expected 2023-05-15, got $result"
fi

# Test 3: Valid date pattern YYYYMMDD
touch "20231225_photo.jpg"
result=$(get_file_date "20231225_photo.jpg")
if [[ "$result" == "2023-12-25" ]]; then
    log_pass "Test 3: Valid YYYYMMDD pattern (got $result)"
else
    log_fail "Test 3: Expected 2023-12-25, got $result"
fi

# Test 4: Invalid year (future)
touch -t 202301150930 "2999-05-15_photo.jpg"
result=$(get_file_date "2999-05-15_photo.jpg")
if [[ "$result" == "2023-01-15" ]]; then
    log_pass "Test 4: Future year rejected, uses file date (got $result)"
else
    log_fail "Test 4: Expected 2023-01-15, got $result"
fi

# Test 5: Invalid year (too old)
touch -t 202301150930 "1899-05-15_photo.jpg"
result=$(get_file_date "1899-05-15_photo.jpg")
if [[ "$result" == "2023-01-15" ]]; then
    log_pass "Test 5: Year < 1900 rejected, uses file date (got $result)"
else
    log_fail "Test 5: Expected 2023-01-15, got $result"
fi

# Test 6: Invalid month (13)
touch -t 202301150930 "2023-13-15_photo.jpg"
result=$(get_file_date "2023-13-15_photo.jpg")
if [[ "$result" == "2023-01-15" ]]; then
    log_pass "Test 6: Month 13 rejected, uses file date (got $result)"
else
    log_fail "Test 6: Expected 2023-01-15, got $result"
fi

# Test 7: Invalid month (00)
touch -t 202301150930 "2023-00-15_photo.jpg"
result=$(get_file_date "2023-00-15_photo.jpg")
if [[ "$result" == "2023-01-15" ]]; then
    log_pass "Test 7: Month 00 rejected, uses file date (got $result)"
else
    log_fail "Test 7: Expected 2023-01-15, got $result"
fi

# Test 8: Invalid day (32)
touch -t 202301150930 "2023-05-32_photo.jpg"
result=$(get_file_date "2023-05-32_photo.jpg")
if [[ "$result" == "2023-01-15" ]]; then
    log_pass "Test 8: Day 32 rejected, uses file date (got $result)"
else
    log_fail "Test 8: Expected 2023-01-15, got $result"
fi

# Test 9: Invalid day (00)
touch -t 202301150930 "2023-05-00_photo.jpg"
result=$(get_file_date "2023-05-00_photo.jpg")
if [[ "$result" == "2023-01-15" ]]; then
    log_pass "Test 9: Day 00 rejected, uses file date (got $result)"
else
    log_fail "Test 9: Expected 2023-01-15, got $result"
fi

# Test 10: Valid DD-MM-YYYY pattern
touch "15-05-2023_photo.jpg"
result=$(get_file_date "15-05-2023_photo.jpg")
if [[ "$result" == "2023-05-15" ]]; then
    log_pass "Test 10: Valid DD-MM-YYYY pattern (got $result)"
else
    log_fail "Test 10: Expected 2023-05-15, got $result"
fi

# Test 11: Valid edge case - year 1900
touch "1900-01-01_photo.jpg"
result=$(get_file_date "1900-01-01_photo.jpg")
if [[ "$result" == "1900-01-01" ]]; then
    log_pass "Test 11: Year 1900 accepted (got $result)"
else
    log_fail "Test 11: Expected 1900-01-01, got $result"
fi

# Test 12: Valid edge case - current year
current_year=$(date +%Y)
touch "${current_year}-12-31_photo.jpg"
result=$(get_file_date "${current_year}-12-31_photo.jpg")
if [[ "$result" == "${current_year}-12-31" ]]; then
    log_pass "Test 12: Current year accepted (got $result)"
else
    log_fail "Test 12: Expected ${current_year}-12-31, got $result"
fi

# Cleanup
cd /
rm -rf "$TEST_DIR"

echo ""
echo "---------------------------------------"
echo "Results: $pass PASS / $fail FAIL"
if [ $fail -eq 0 ]; then
    echo -e "${GREEN}✅ ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "${RED}❌ SOME TESTS FAILED${NC}"
    exit 1
fi
