#!/bin/bash
set -euo pipefail
export PATH="$HOME/.npm-global/bin:$PATH"

WIN_INPUT="/mnt/c/Users/thies/Documents/sumup"
WSL_WORK="$HOME/sumup/workspace"
WSL_OUTPUT="$WSL_WORK/summaries"
WSL_STATE="$WSL_WORK/.state"
WIN_OUTPUT="/mnt/c/Users/thies/Documents/sumup/summaries"

TIMEOUT_DOC=240
TIMEOUT_REDUCE=900
MAX_RETRIES=2
GROUP_SIZE=3

# --- Defaults ---
PIPELINE_MODE="full"
ANKI_STYLE="medium"
EXTRACT_MODE="none"
OVERWRITE=0
MODEL="zai-coding-plan/glm-5-turbo"
API_CONCURRENCY=2
EXTRACT_CONCURRENCY=4
DRY_RUN=0
CLEAN_MODE=0

# --- Helpers ---
log() { echo "$*"; }
warn() { echo "$*" >&2; }
require_cmd() {
  local cmd="$1" hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    warn "✗ ERROR: Required command missing: $cmd${hint:+ ($hint)}"
    exit 1
  fi
}

safe_wait_all() {
  local rc=0 pid
  for pid in "$@"; do
    if ! wait "$pid" 2>/dev/null; then
      rc=1
    fi
  done
  return "$rc"
}

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--clean)   CLEAN_MODE=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [OPTIONS]
  -c, --clean    Wipe workspace before running
  -n, --dry-run  Do not call APIs or OCR, just simulate outputs
  -h, --help     Show this help
EOF
      exit 0
      ;;
    *)
      warn "✗ ERROR: Unknown argument: $1"
      exit 1
      ;;
  esac
  shift
done

if [ "$CLEAN_MODE" -eq 1 ]; then
  log "🧹 Clean mode activated: Wiping workspace..."
  rm -rf "$WSL_WORK"
fi

mkdir -p "$WSL_OUTPUT" "$WSL_STATE" "$WIN_OUTPUT" "$WSL_WORK"

# --- Interactive Menus ---

choose_pipeline() {
  echo ""
  echo "Choose Pipeline Mode:"
  echo "  1) Full Pipeline (Summaries + Anki + Old Exams)"
  echo "  2) Only Anki Generation (Direct from text, skip summaries)"
  echo "  3) Only Summary Generation (Skip Anki)"
  echo "  4) Only Old Exam Ankis (Solve old exams, skip everything else)"
  echo ""
  read -rp "Enter choice [1-4] (default 1): " P_CHOICE
  case "$P_CHOICE" in
    2) PIPELINE_MODE="anki_only" ;;
    3) PIPELINE_MODE="summary_only" ;;
    4) PIPELINE_MODE="oldexam_only" ;;
    *) PIPELINE_MODE="full" ;;
  esac
}

choose_anki_style() {
  if [ "$PIPELINE_MODE" = "summary_only" ] || [ "$PIPELINE_MODE" = "oldexam_only" ]; then
    ANKI_STYLE="none"
    return
  fi

  echo ""
  echo "Choose Anki Card Style:"
  echo "  1) Atomic (1 Fact Max - Strict SuperMemo rules)"
  echo "  2) Medium (Slightly bigger, 2 to 3 related facts per card)"
  echo "  3) Comprehensive (Big cards covering small topics)"
  echo ""
  read -rp "Enter choice [1-3] (default 2): " A_CHOICE
  case "$A_CHOICE" in
    1) ANKI_STYLE="atomic" ;;
    3) ANKI_STYLE="comprehensive" ;;
    *) ANKI_STYLE="medium" ;;
  esac
}

choose_extraction_mode() {
  echo ""
  echo "Choose PDF Extraction Mode:"
  echo "  1) No OCR (Fastest) - Reads native text only."
  echo "  2) Tesseract (Fast OCR) - Standard accuracy."
  echo "  3) DocTR / Mindee (Slow OCR) - High accuracy AI model."
  echo ""
  read -rp "Enter choice [1-3] (default 1): " E_CHOICE
  case "$E_CHOICE" in
    2) EXTRACT_MODE="tesseract" ;;
    3) EXTRACT_MODE="doctr" ;;
    *) EXTRACT_MODE="none" ;;
  esac

  if [ "$EXTRACT_MODE" = "tesseract" ]; then
    if ! command -v tesseract >/dev/null 2>&1 || ! command -v pdftoppm >/dev/null 2>&1; then
      warn "✗ ERROR: Tesseract dependencies missing. Run: sudo apt-get install tesseract-ocr poppler-utils"
      exit 1
    fi
  fi

  if [ "$EXTRACT_MODE" = "doctr" ]; then
    if ! ldconfig -p 2>/dev/null | grep -q libGL; then
      warn "✗ ERROR: DocTR requires libgl1. Run: sudo apt-get install libgl1"
      exit 1
    fi
  fi

  local cores
  cores=$(nproc 2>/dev/null || echo 4)
  if [ "$EXTRACT_MODE" = "doctr" ]; then
    EXTRACT_CONCURRENCY=3
  elif [ "$EXTRACT_MODE" = "tesseract" ]; then
    EXTRACT_CONCURRENCY=$(( cores / 2 ))
  else
    EXTRACT_CONCURRENCY=$cores
  fi
  [ "$EXTRACT_CONCURRENCY" -lt 1 ] && EXTRACT_CONCURRENCY=1
}

choose_overwrite() {
  echo ""
  echo "Overwrite Behavior:"
  echo "  1) Skip existing files (Resume/Fast)"
  echo "  2) Overwrite existing files (Force regenerate)"
  echo ""
  read -rp "Enter choice [1-2] (default 1): " O_CHOICE
  case "$O_CHOICE" in
    2) OVERWRITE=1 ;;
    *) OVERWRITE=0 ;;
  esac
}

choose_model() {
  echo ""
  echo "Choose model:"
  echo "  1) GLM-4.7"
  echo "  2) GLM-5"
  echo "  3) GLM-5.1"
  echo "  4) GLM-5-Turbo"
  echo ""
  read -rp "Enter choice [1-4] (default 4): " CHOICE
  case "$CHOICE" in
    1) MODEL="zai-coding-plan/glm-4.7" ;;
    2) MODEL="zai-coding-plan/glm-5" ;;
    3) MODEL="zai-coding-plan/glm-5.1" ;;
    *) MODEL="zai-coding-plan/glm-5-turbo" ;;
  esac
}

choose_api_concurrency() {
  echo ""
  echo "Choose API concurrency level (1-10 parallel jobs for Model calls):"
  echo "  Default is 2."
  read -rp "Enter choice (or press Enter for 2): " C_CHOICE
  if [[ "$C_CHOICE" =~ ^[0-9]+$ ]] && [ "$C_CHOICE" -gt 0 ]; then
    API_CONCURRENCY="$C_CHOICE"
  elif [[ -n "$C_CHOICE" ]]; then
    echo "  Invalid input, using default: $API_CONCURRENCY"
  fi
}

# --- Pre-Flight Setup ---

setup_dependencies() {
  log "[Setup] Verifying Python dependencies & models (Single Thread)..."
  require_cmd python3 "install Python 3"
  require_cmd timeout "install coreutils"
  require_cmd find
  require_cmd flock
  require_cmd cp
  require_cmd grep
  require_cmd sort
  require_cmd xargs

  if [ "$EXTRACT_MODE" = "none" ]; then
    require_cmd pdftotext "sudo apt-get install poppler-utils"
  fi

  if [ "$EXTRACT_MODE" = "doctr" ]; then
    if ! python3 -c "import doctr, fitz, onnxruntime" 2>/dev/null; then
      log "  → Installing PyTorch (CPU version to skip NVIDIA bloat)..."
      if ! python3 -m pip install --default-timeout=1000 --break-system-packages torch torchvision --index-url https://download.pytorch.org/whl/cpu; then
        warn "  ✗ ERROR: Failed to download PyTorch (CPU)."
        exit 1
      fi

      log "  → Installing Mindee DocTR & ONNX..."
      if ! python3 -m pip install --default-timeout=1000 --break-system-packages python-doctr pymupdf onnxruntime; then
        warn "  ✗ ERROR: Failed to download dependencies."
        exit 1
      fi
    fi

    log "  → Verifying AI Model weights..."
    if ! python3 -c "
import os, logging
os.environ['USE_TF'] = '0'
os.environ['USE_TORCH'] = '1'
os.environ['TF_CPP_MIN_LOG_LEVEL'] = '3'
logging.getLogger('doctr').setLevel(logging.ERROR)
from doctr.models import ocr_predictor
ocr_predictor(pretrained=True, det_arch='db_resnet50', reco_arch='crnn_vgg16_bn')
" 2>/dev/null; then
      warn "  ✗ ERROR: Failed to fetch model weights. Check connection."
      exit 1
    fi
  else
    if ! python3 -c "import fitz" 2>/dev/null; then
      log "  → Installing PyMuPDF (Native Extractor)..."
      if ! python3 -m pip install --default-timeout=1000 --break-system-packages -q pymupdf; then
        warn "  ✗ ERROR: Failed to download PyMuPDF."
        exit 1
      fi
    fi
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    require_cmd opencode "install/configure OpenCode CLI"
  fi

  log "  ✓ Dependencies OK"
}

# --- Extraction Logic ---

extract_pdf_native() {
  local pdf="$1" txt="$2"
  if command -v pdftotext >/dev/null 2>&1 && pdftotext -layout -enc UTF-8 "$pdf" "$txt" 2>/dev/null; then
    return 0
  fi
  python3 - "$pdf" "$txt" <<'PY'
import sys
import fitz
pdf, out = sys.argv[1], sys.argv[2]
doc = fitz.open(pdf)
text = "\n\n".join(f"=== PAGE {i+1} ===\n{p.get_text('text')}" for i, p in enumerate(doc))
open(out, "w", encoding="utf-8").write(text)
PY
}

extract_pdf_tesseract() {
  local pdf="$1" txt="$2"
  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' RETURN

  pdftoppm -png "$pdf" "$tmp_dir/page" >/dev/null 2>&1 || true
  : > "$txt"

  shopt -s nullglob
  local images=("$tmp_dir"/page-*.png)
  shopt -u nullglob
  if [ "${#images[@]}" -eq 0 ]; then
    return 1
  fi

  printf '%s\n' "${images[@]}" | sort -V | \
    xargs -P "${EXTRACT_CONCURRENCY:-4}" -I{} sh -c 'tesseract "$1" "$1.out" quiet >/dev/null 2>&1 || exit 1' _ {}

  shopt -s nullglob
  local out_files=("$tmp_dir"/page-*.png.out.txt)
  shopt -u nullglob
  if [ "${#out_files[@]}" -eq 0 ]; then
    return 1
  fi

  printf '%s\n' "${out_files[@]}" | sort -V | while IFS= read -r f; do
    cat "$f"
  done >> "$txt"
}

extract_pdf_doctr() {
  local pdf="$1" txt="$2"
  python3 - "$pdf" "$txt" <<'PY'
import sys
import os
import logging

os.environ["USE_TF"] = "0"
os.environ["USE_TORCH"] = "1"
os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3"
logging.getLogger("doctr").setLevel(logging.ERROR)

from doctr.io import DocumentFile
from doctr.models import ocr_predictor

pdf_path, out_path = sys.argv[1], sys.argv[2]
try:
    doc = DocumentFile.from_pdf(pdf_path)
    predictor = ocr_predictor(pretrained=True, det_arch='db_resnet50', reco_arch='crnn_vgg16_bn')
    res = predictor(doc)

    out_text = ""
    for i, page in enumerate(res.pages):
        out_text += f"=== PAGE {i+1} ===\n"
        for block in page.blocks:
            for line in block.lines:
                out_text += " ".join(word.value for word in line.words) + "\n"
            out_text += "\n"

    with open(out_path, "w", encoding="utf-8") as f:
        f.write(out_text)
except Exception:
    sys.exit(1)
PY
}

do_extract() {
  local pdf="$1" txt="$2"
  if [ "$EXTRACT_MODE" = "tesseract" ]; then
    extract_pdf_tesseract "$pdf" "$txt"
  elif [ "$EXTRACT_MODE" = "doctr" ]; then
    extract_pdf_doctr "$pdf" "$txt"
  else
    extract_pdf_native "$pdf" "$txt"
  fi
}

# --- Prompts ---

write_single_prompt() {
  local title="$1" outfile="$2" prompt_file="$3" course="$4"
  cat > "$prompt_file" <<PROMPT
You are an expert academic summarizer for university students.
Create a highly detailed and comprehensive study summary from the single attached text.
Do NOT include a "standalone facts" or "must-knows" list at the end.
Instead, integrate all vital facts deeply into the main body sections.
Write the final result to this exact path: ${outfile}

# ${course} — ${title}

Provide a detailed 1-paragraph overview.
## Mechanisms & Pathways
- Highly detailed bullet points and numbered steps.
- Explain the "why" and "how" thoroughly.
## Key Definitions & Concepts
| Term | Comprehensive Meaning |
|---|---|
## Important Distinctions & Comparisons
- Detail A vs B comparisons, exceptions, and commonly confused pairs.
## Clinical / Practical Relevance
- Thoroughly detail diseases, treatments, applications, and consequences.
Rules:
- Paraphrase for clarity but preserve exact names, numbers, and scientific terms.
- Use only the attached file as source material.
PROMPT
}

write_anki_prompt() {
  local title="$1" outfile="$2" prompt_file="$3" course="$4"
  local tag
  tag=$(echo "${course}::${title}" | tr ' ' '_' | tr -d ',"')

  cat > "$prompt_file" <<PROMPT
You are an expert Anki flashcard creator.
Your job is to analyze the attached text and create highly effective flashcards based on the requested style.

Write the final result to this exact path: ${outfile}

CRITICAL FORMAT RULES:
1. First 4 lines MUST be:
#separator:Comma
#html:false
#notetype:Basic
#deck:SumUp::${course}
2. Line 5: "Front","Back","Tags"
3. Every row: "question","answer","${tag}"
4. NO markdown code blocks, NO backticks.
5. Escape internal quotes by doubling them up (""like this"") as per standard CSV formatting.

STYLE INSTRUCTIONS:
PROMPT

  if [ "$ANKI_STYLE" = "atomic" ]; then
    cat >> "$prompt_file" <<PROMPT
Strictly follow Piotr Wozniak's "20 Rules of Formulating Knowledge":
1. Minimum Information Principle (Keep it simple): Each card MUST test exactly ONE highly atomic fact.
2. Extremely short answers: The "Back" of the card should be 1-5 words maximum. Never write full paragraphs.
3. Avoid sets and enumerations.
4. Prevent interference: Ensure the "Front" provides enough context.
5. High Volume: Minimum 30-40 cards per document.
PROMPT
  elif [ "$ANKI_STYLE" = "medium" ]; then
    cat >> "$prompt_file" <<PROMPT
1. Medium Focus: Group 2 to 3 closely related facts or concepts together per card.
2. Structure: The "Back" of the card should use short bullet points to list the facts clearly.
3. Cueing: The "Front" should ask a slightly broader but targeted question.
PROMPT
  elif [ "$ANKI_STYLE" = "comprehensive" ]; then
    cat >> "$prompt_file" <<PROMPT
1. Comprehensive Focus: Create large, detailed cards that cover entire small topics.
2. Open-ended Cues: The "Front" should ask a broad question.
3. Detailed Answers: The "Back" should be a comprehensive paragraph or a detailed list.
PROMPT
  fi
}

write_master_prompt() {
  local outfile="$1" prompt_file="$2" course="$3"; shift 3
  local file_list=""
  for f in "$@"; do file_list="$file_list- $(basename "$f")"$'\n'; done

  cat > "$prompt_file" <<PROMPT
You are combining university study summaries into a master document for the subject: ${course}.
You are reading attached .md files. Keep ALL details and facts, remove only exact duplicates.
CRITICAL INSTRUCTIONS:
1. Group related topics into logical thematic chapters. Do not just list them file-by-file.
2. Include a "Source Documents" section listing the exact files included.
3. Do NOT add a list of standalone facts at the end.
Write the final result to this exact path: ${outfile}

# Master Summary — ${course}

**Source Documents Included in this Batch:**
${file_list}

## Chapter 1: [Grouped Theme]
### [Subtopic]
- Highly detailed combined bullets preserving all mechanisms.
#### Key Distinctions
- Combined comparisons.
PROMPT
}

write_master_anki_prompt() {
  local outfile="$1" prompt_file="$2" course="$3"
  cat > "$prompt_file" <<PROMPT
You are combining multiple Anki CSV files into one master deck for: ${course}.
You are ONLY reading the attached .csv files.

Write the final result to this exact path: ${outfile}

CRITICAL FORMAT RULES:
1. First 4 lines must be:
#separator:Comma
#html:false
#notetype:Basic
#deck:SumUp::${course}
2. Line 5: "Front","Back","Tags"
3. Every card: "question","answer","Tags"
4. NO markdown, NO backticks.
TASKS:
- Combine all cards into one file.
- Remove EXACT duplicate questions.
- Do NOT alter the format or structure of the questions and answers.
PROMPT
}

write_oldexam_prompt() {
  local outfile="$1" prompt_file="$2" course="$3"
  cat > "$prompt_file" <<PROMPT
System Role: You are a University Professor creating Anki flashcards from past exams.
Context: You are provided with an old exam document and a MASTER SUMMARY for the course ${course}.
Task: Extract questions from the exam document. Solve them strictly using the MASTER SUMMARY and general academic knowledge.
CRITICAL: Ignore any handwritten marks, stars, or pre-selected answers in the exam documents as they may be incorrect. You must determine the correct answer yourself.

Output Format: Provide the output in a single code block. CRITICAL: Use the vertical pipe symbol | as the field separator. Do not use Tabs.
Structure: Question | Answer (HTML) | Tag

Columns:
Front: The full question text including answer possibilities + Question Number.
Back for MCQs:
- List ALL options provided in the question.
- Format the CORRECT option exactly like this: <font color="#00ff00"><b>Option Text</b></font>
- Format INCORRECT options exactly like this: <font color="#ff0000">Option Text</font>
- Below the options, add a <br><br> tag, then provide a concise explanation referencing the summary. Bold critical facts using <b>tags</b>.
Back for Free/Open Questions:
- Provide the answer in bullet points using HTML: <ul><li>Point 1</li><li>Point 2</li></ul>
- Reference the specific section from the summary.
Tag: ${course}_OldExam

Execution: Process all unique questions found in the attached exam document.
Write the final result to this exact path: ${outfile}
PROMPT
}

# --- Execution Core ---

with_retry() {
  local retries=$1 name=$2; shift 2
  local count=0
  while true; do
    if "$@"; then return 0; fi
    if [ "$count" -ge "$retries" ]; then
      warn "  ✗ [$name] failed after $retries retries"
      return 1
    fi
    count=$((count + 1))
    log "  ↻ [$name] retry $count/$retries..."
    sleep 3
  done
}

run_model() {
  local input_file="$1" prompt_file="$2" expected_output="$3" log_file="$4" out_dir="$5"
  rm -f "$expected_output"
  if ! ( cd "$out_dir" && timeout "$TIMEOUT_DOC" opencode run -m "$MODEL" -f "$input_file" < "$prompt_file" > "$log_file" 2>&1 ); then
    return 1
  fi
  [ -s "$expected_output" ]
}

run_master_model() {
  local expected_output="$1" prompt_file="$2" log_file="$3" out_dir="$4"; shift 4
  rm -f "$expected_output"
  local file_args=()
  for f in "$@"; do file_args+=("-f" "$f"); done
  if ! ( cd "$out_dir" && timeout "$TIMEOUT_REDUCE" opencode run -m "$MODEL" "${file_args[@]}" < "$prompt_file" > "$log_file" 2>&1 ); then
    return 1
  fi
  [ -s "$expected_output" ]
}

validate_csv() {
  python3 - "$1" <<'PY'
import csv, sys
path = sys.argv[1]
try:
    with open(path, encoding='utf-8', newline='') as f:
        rows = list(csv.reader(f))

    if len(rows) < 6:
        raise SystemExit(1)

    if rows[0] != ['#separator:Comma']:
        raise SystemExit(1)
    if rows[1] != ['#html:false']:
        raise SystemExit(1)
    if rows[2] != ['#notetype:Basic']:
        raise SystemExit(1)
    if not rows[3] or not rows[3][0].startswith('#deck:SumUp::'):
        raise SystemExit(1)
    if rows[4] != ['Front', 'Back', 'Tags']:
        raise SystemExit(1)

    data_rows = rows[5:]
    if not data_rows:
        raise SystemExit(1)

    for r in data_rows:
        if len(r) != 3:
            raise SystemExit(1)
        if not r[0].strip() or not r[1].strip() or not r[2].strip():
            raise SystemExit(1)
except Exception:
    raise SystemExit(1)
PY
}

# Phase 1: Local Extraction
extract_document() {
  local pdf="$1" total_docs="$2"

  local wsl_work_norm="${WSL_WORK%/}"
  if [[ "$pdf" != "$wsl_work_norm/"* ]]; then return 1; fi

  local rel_path="${pdf#$wsl_work_norm/}"

  if [ "$PIPELINE_MODE" = "oldexam_only" ] && [[ "$rel_path" != *"/oldexams/"* ]]; then
    return 0
  fi

  local dir_name
  dir_name="$(dirname "$rel_path")"
  local base
  base="$(basename "$pdf" .pdf)"

  local course_name="$dir_name"
  [ "$course_name" = "." ] && course_name="General"

  local txt="${pdf%.pdf}__extracted.txt"
  local out_dir="$WSL_OUTPUT/$dir_name"
  local state_dir="$WSL_STATE/$dir_name"
  mkdir -p "$out_dir" "$state_dir"

  local md="$out_dir/${base}.md"
  local csv="$out_dir/${base}.csv"

  local needs_summary=0
  local needs_anki=0

  if [ "$PIPELINE_MODE" = "full" ] || [ "$PIPELINE_MODE" = "summary_only" ]; then
    if [ ! -s "$md" ] || [ "$OVERWRITE" -eq 1 ]; then needs_summary=1; fi
  fi
  if [ "$PIPELINE_MODE" = "full" ] || [ "$PIPELINE_MODE" = "anki_only" ]; then
    if [ ! -s "$csv" ] || [ "$OVERWRITE" -eq 1 ]; then needs_anki=1; fi
  fi
  if [[ "$rel_path" == *"/oldexams/"* ]]; then
    needs_summary=0
    needs_anki=1
  fi

  local current
  current=$(
    exec 200>"$WSL_STATE/.ext_lock"
    flock 200
    echo 1 >> "$WSL_STATE/.ext_progress"
    wc -l < "$WSL_STATE/.ext_progress" | tr -d ' '
  )
  local prefix="[$current/$total_docs]"

  if [ "$needs_summary" -eq 1 ] || [ "$needs_anki" -eq 1 ]; then
    if [ ! -s "$txt" ] || [ "$OVERWRITE" -eq 1 ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        log "  $prefix (Dry Run) Extracting text: $base"
        printf 'DRY RUN\n' > "$txt"
      else
        log "  $prefix Extracting: $base"
        rm -f "$txt"
        if ! do_extract "$pdf" "$txt" || [ ! -s "$txt" ]; then
          warn "  ✗ $prefix Failed to extract: $base"
          rm -f "$txt"
          touch "$state_dir/${base}.failed"
        fi
      fi
    else
      log "  ✓ $prefix Extracted text exists: $base"
    fi
  else
    log "  ✓ $prefix Content already exists: $base"
  fi
}

# Phase 2: API Generation
process_api_document() {
  if [ "$PIPELINE_MODE" = "oldexam_only" ]; then return 0; fi

  local pdf="$1" total_docs="$2"

  local wsl_work_norm="${WSL_WORK%/}"
  if [[ "$pdf" != "$wsl_work_norm/"* ]]; then return 1; fi

  local rel_path="${pdf#$wsl_work_norm/}"

  if [[ "$rel_path" == *"/oldexams/"* ]]; then return 0; fi

  local dir_name
  dir_name="$(dirname "$rel_path")"
  local base
  base="$(basename "$pdf" .pdf)"

  local course_name="$dir_name"
  [ "$course_name" = "." ] && course_name="General"

  local txt="${pdf%.pdf}__extracted.txt"
  local out_dir="$WSL_OUTPUT/$dir_name"
  local state_dir="$WSL_STATE/$dir_name"

  local md="$out_dir/${base}.md"
  local csv="$out_dir/${base}.csv"

  if [ -f "$state_dir/${base}.failed" ]; then return 1; fi
  if [ ! -s "$txt" ]; then
    warn "  ✗ Source text missing or empty for: $course_name/$base"
    touch "$state_dir/${base}.failed"
    return 1
  fi

  local needs_summary=0
  local needs_anki=0

  if [ "$PIPELINE_MODE" = "full" ] || [ "$PIPELINE_MODE" = "summary_only" ]; then
    if [ ! -s "$md" ] || [ "$OVERWRITE" -eq 1 ]; then needs_summary=1; fi
  fi
  if [ "$PIPELINE_MODE" = "full" ] || [ "$PIPELINE_MODE" = "anki_only" ]; then
    if [ ! -s "$csv" ] || [ "$OVERWRITE" -eq 1 ]; then needs_anki=1; fi
  fi

  if [ "$needs_summary" -eq 0 ] && [ "$needs_anki" -eq 0 ]; then return 0; fi

  local current
  current=$(
    exec 200>"$WSL_STATE/.api_lock"
    flock 200
    echo 1 >> "$WSL_STATE/.api_progress"
    wc -l < "$WSL_STATE/.api_progress" | tr -d ' '
  )
  local prefix="[$current/API-Queue]"

  if [ "$needs_summary" -eq 1 ]; then
    write_single_prompt "$base" "$md" "$state_dir/${base}_sum.txt" "$course_name"
    log "  → $prefix Summarizing: $course_name / $base"

    if [ "$DRY_RUN" -eq 1 ]; then
      printf '# Dry run\n' > "$md"
    else
      if with_retry "$MAX_RETRIES" "Summary $base" run_model "$txt" "$state_dir/${base}_sum.txt" "$md" "$state_dir/${base}_sum.log" "$out_dir"; then
        log "  ✓ $prefix ${base}.md"
      else
        touch "$state_dir/${base}.failed"
        return 1
      fi
    fi
  fi

  if [ "$needs_anki" -eq 1 ]; then
    local anki_source="$txt"
    [ "$PIPELINE_MODE" = "full" ] && anki_source="$md"

    if [ -s "$anki_source" ]; then
      write_anki_prompt "$base" "$csv" "$state_dir/${base}_anki.txt" "$course_name"
      log "  → $prefix Anki: $course_name / $base"

      if [ "$DRY_RUN" -eq 1 ]; then
        cat > "$csv" <<EOF
#separator:Comma
#html:false
#notetype:Basic
#deck:SumUp::${course_name}
Front,Back,Tags
"Dry run question","Dry run answer","${course_name}_${base}"
EOF
      else
        if with_retry "$MAX_RETRIES" "Anki $base" run_model "$anki_source" "$state_dir/${base}_anki.txt" "$csv" "$state_dir/${base}_anki.log" "$out_dir"; then
          if validate_csv "$csv"; then
            log "  ✓ $prefix ${base}.csv (Validated)"
          else
            warn "  ✗ $prefix ${base}.csv failed validation (Malformed CSV)"
            rm -f "$csv"
            touch "$state_dir/${base}.failed"
            return 1
          fi
        else
          touch "$state_dir/${base}.failed"
          return 1
        fi
      fi
    else
      if [ "$DRY_RUN" -eq 0 ]; then
        warn "  ✗ Source missing for Anki: $course_name/$base"
        touch "$state_dir/${base}.failed"
        return 1
      fi
    fi
  fi
}

process_master() {
  if [ "$PIPELINE_MODE" = "oldexam_only" ]; then return 0; fi

  local d="$1"
  if [[ "$d" == *"/oldexams"* ]]; then return 0; fi

  local course_name
  course_name="$(basename "$d")"
  [ "$course_name" = "summaries" ] && course_name="General"

  local wsl_output_norm="${WSL_OUTPUT%/}"
  local relative="${d#$wsl_output_norm/}"
  [ "$relative" = "$d" ] && relative=""

  local state_dir="$WSL_STATE${relative:+/$relative}"
  mkdir -p "$state_dir"

  if find "$state_dir" -maxdepth 1 -name '*.failed' -print -quit | grep -q .; then
    log "  ⚠ Skipping Master Files for $course_name (Contains failed documents)"
    return 0
  fi

  if [ "$PIPELINE_MODE" = "full" ] || [ "$PIPELINE_MODE" = "summary_only" ]; then
    local MD_LIST=()
    while IFS= read -r -d '' f; do MD_LIST+=("$f"); done < <(find "$d" -maxdepth 1 -name '*.md' ! -iname 'master_summary*' -print0 | sort -z)

    if [ "${#MD_LIST[@]}" -gt 0 ]; then
      log "  → Compiling Master Summary: $course_name (${#MD_LIST[@]} files)"
      local TOTAL_MDS=${#MD_LIST[@]}
      if [ "$TOTAL_MDS" -gt "$GROUP_SIZE" ]; then
        local BATCH_COUNT=1
        local batch_pids=()

        for (( i=0; i<TOTAL_MDS; i+=GROUP_SIZE )); do
          local BATCH_FILES=("${MD_LIST[@]:i:GROUP_SIZE}")
          local BATCH_OUT="$d/MASTER_SUMMARY_Part${BATCH_COUNT}.md"

          if [ ! -s "$BATCH_OUT" ] || [ "$OVERWRITE" -eq 1 ]; then
            write_master_prompt "$BATCH_OUT" "$state_dir/master_sum_pt${BATCH_COUNT}.txt" "$course_name" "${BATCH_FILES[@]}"
            if [ "$DRY_RUN" -eq 1 ]; then
              printf '# Dry run\n' > "$BATCH_OUT"
            else
              (
                if with_retry "$MAX_RETRIES" "Master Summary Part $BATCH_COUNT" run_master_model "$BATCH_OUT" "$state_dir/master_sum_pt${BATCH_COUNT}.txt" "$state_dir/master_sum_pt${BATCH_COUNT}.log" "$d" "${BATCH_FILES[@]}"; then
                  log "    ✓ Part ${BATCH_COUNT}"
                else
                  warn "    ✗ Part $BATCH_COUNT failed"
                  exit 1
                fi
              ) &
              batch_pids+=($!)
              while [ "${#batch_pids[@]}" -ge "$API_CONCURRENCY" ]; do
                if ! wait "${batch_pids[0]}" 2>/dev/null; then :; fi
                batch_pids=("${batch_pids[@]:1}")
              done
            fi
          fi
          BATCH_COUNT=$((BATCH_COUNT + 1))
        done
        safe_wait_all "${batch_pids[@]:-}" || true

        shopt -s nullglob
        local PART_FILES=("$d"/MASTER_SUMMARY_Part*.md)
        shopt -u nullglob

        if [ "${#PART_FILES[@]}" -gt 0 ]; then
          local FINAL_MD="$d/MASTER_SUMMARY.md"
          if [ ! -s "$FINAL_MD" ] || [ "$OVERWRITE" -eq 1 ]; then
            log "  → Merging Parts into FINAL MASTER SUMMARY: $course_name"
            write_master_prompt "$FINAL_MD" "$state_dir/master_reduce.txt" "$course_name" "${PART_FILES[@]}"
            if [ "$DRY_RUN" -eq 1 ]; then
              printf '# Dry run\n' > "$FINAL_MD"
            else
              if with_retry "$MAX_RETRIES" "Master Reduce" run_master_model "$FINAL_MD" "$state_dir/master_reduce.txt" "$state_dir/master_reduce.log" "$d" "${PART_FILES[@]}"; then
                log "    ✓ Final MASTER_SUMMARY.md merged"
              else
                warn "    ✗ Master Reduce failed"
              fi
            fi
          fi
        fi
      else
        local MASTER_MD="$d/MASTER_SUMMARY.md"
        if [ ! -s "$MASTER_MD" ] || [ "$OVERWRITE" -eq 1 ]; then
          write_master_prompt "$MASTER_MD" "$state_dir/master_sum.txt" "$course_name" "${MD_LIST[@]}"
          if [ "$DRY_RUN" -eq 1 ]; then
            printf '# Dry run\n' > "$MASTER_MD"
          else
            if with_retry "$MAX_RETRIES" "Master Summary" run_master_model "$MASTER_MD" "$state_dir/master_sum.txt" "$state_dir/master_sum.log" "$d" "${MD_LIST[@]}"; then
              log "    ✓ MASTER_SUMMARY.md"
            else
              warn "    ✗ Master Summary failed"
            fi
          fi
        fi
      fi
    fi
  fi

  if [ "$PIPELINE_MODE" = "full" ] || [ "$PIPELINE_MODE" = "anki_only" ]; then
    local CSV_LIST=()
    while IFS= read -r -d '' f; do CSV_LIST+=("$f"); done < <(find "$d" -maxdepth 1 -name '*.csv' ! -iname 'master_anki*' -print0 | sort -z)
    if [ "${#CSV_LIST[@]}" -gt 0 ]; then
      local MASTER_CSV="$d/MASTER_ANKI.csv"
      if [ ! -s "$MASTER_CSV" ] || [ "$OVERWRITE" -eq 1 ]; then
        log "  → Compiling Master Anki: $course_name"
        write_master_anki_prompt "$MASTER_CSV" "$state_dir/master_anki.txt" "$course_name"
        if [ "$DRY_RUN" -eq 1 ]; then
          cat > "$MASTER_CSV" <<EOF
#separator:Comma
#html:false
#notetype:Basic
#deck:SumUp::${course_name}
Front,Back,Tags
"Dry run question","Dry run answer","${course_name}_master"
EOF
        else
          if with_retry "$MAX_RETRIES" "Master Anki" run_master_model "$MASTER_CSV" "$state_dir/master_anki.txt" "$state_dir/master_anki.log" "$d" "${CSV_LIST[@]}"; then
            if validate_csv "$MASTER_CSV"; then
              log "    ✓ MASTER_ANKI.csv"
            else
              warn "    ✗ MASTER_ANKI.csv failed validation"
              rm -f "$MASTER_CSV"
            fi
          else
            warn "    ✗ Master Anki failed"
          fi
        fi
      fi
    fi
  fi
}

process_oldexam() {
  local pdf="$1"
  local wsl_work_norm="${WSL_WORK%/}"

  if [[ "$pdf" != "$wsl_work_norm/"* ]]; then
    warn "  ✗ Error: $pdf is not under WSL_WORK ($wsl_work_norm)"
    return 1
  fi

  local rel_path="${pdf#$wsl_work_norm/}"
  local dir_name
  dir_name="$(dirname "$rel_path")"
  local course_dir
  course_dir="$(dirname "$dir_name")"
  local base
  base="$(basename "$pdf" .pdf)"

  [ "$dir_name" = "." ] && dir_name="General"
  [ "$course_dir" = "." ] && course_dir="General"

  local txt="${pdf%.pdf}__extracted.txt"
  local course_out_dir="$WSL_OUTPUT/$course_dir"
  local state_dir="$WSL_STATE/$dir_name"

  local exam_anki_dir="$course_out_dir/exam_ankis"
  mkdir -p "$exam_anki_dir" "$state_dir"

  local solved_txt="$exam_anki_dir/${base}_solved.txt"
  local master_md="$course_out_dir/MASTER_SUMMARY.md"

  if [ ! -s "$txt" ]; then return 1; fi

  if [ ! -s "$master_md" ]; then
    log "  ⚠ Skipping Old Exam $base: MASTER_SUMMARY.md not found in $course_dir as source of truth."
    if [ "$PIPELINE_MODE" = "oldexam_only" ]; then
      warn "  ✗ ERROR: oldexam_only mode requires pre-existing MASTER_SUMMARY.md files. Run a summary pass first."
    fi
    return 1
  fi

  if [ -f "$state_dir/${base}.failed" ]; then
    log "  ⚠ Previous failure detected for $base, attempting re-run"
    rm -f "$state_dir/${base}.failed" "$solved_txt"
  fi

  if [ ! -s "$solved_txt" ] || [ "$OVERWRITE" -eq 1 ]; then
    log "  → Solving Old Exam: $course_dir / $base"

    write_oldexam_prompt "$solved_txt" "$state_dir/${base}_prompt.txt" "$(basename "$course_dir")" || {
      warn "  ✗ Failed to write prompt for $base"
      return 1
    }

    if [ "$DRY_RUN" -eq 1 ]; then
      printf 'Question | Answer | Tag\n' > "$solved_txt"
    else
      if with_retry "$MAX_RETRIES" "Old Exam $base" run_master_model "$solved_txt" "$state_dir/${base}_prompt.txt" "$state_dir/${base}_prompt.log" "$exam_anki_dir" "$txt" "$master_md"; then
        log "  ✓ Solved $base -> exam_ankis/${base}_solved.txt"
      else
        warn "  ✗ Failed to solve $base"
        rm -f "$solved_txt"
        touch "$state_dir/${base}.failed"
      fi
    fi
  else
    log "  ✓ Old exam already solved: $base"
  fi
}

# ── Main ─────────────────────────────────────

if [ ! -d "$WIN_INPUT" ]; then warn "✗ Input folder not found: $WIN_INPUT"; exit 1; fi

if [ "$DRY_RUN" -eq 0 ] && [ "$CLEAN_MODE" -eq 0 ]; then
  choose_pipeline
  choose_anki_style
  choose_extraction_mode
  choose_overwrite
  choose_model
  choose_api_concurrency
fi

log ""
log "╔══════════════════════════════════════╗"
log "║      SumUp PDF Pipeline (v25.0)      ║"
log "╚══════════════════════════════════════╝"
[ "$DRY_RUN" -eq 1 ] && log "!!! DRY RUN MODE ACTIVE !!!"
log "Pipeline    : $PIPELINE_MODE"
[ "$PIPELINE_MODE" != "summary_only" ] && [ "$PIPELINE_MODE" != "oldexam_only" ] && log "Anki Style  : $ANKI_STYLE"
log "Extraction  : $EXTRACT_MODE (Local Concurrency: $EXTRACT_CONCURRENCY)"
log "Overwrite   : $( [ "$OVERWRITE" -eq 1 ] && echo "YES" || echo "NO" )"
log "Model       : $MODEL"
log "API Conc.   : $API_CONCURRENCY"
log "Structure   : Recursive Folders Enabled (Old Exams Supported)"
log ""

if [ "$DRY_RUN" -eq 0 ]; then
  setup_dependencies
fi

log ""
log "[1/5] Syncing PDFs to Workspace..."
while IFS= read -r -d '' src; do
  rel="${src#$WIN_INPUT/}"
  dest="$WSL_WORK/$rel"
  if [ ! -f "$dest" ] || [ "$src" -nt "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest" || warn "  ✗ Failed to sync $src"
  fi
done < <(find "$WIN_INPUT" -type f -iname '*.pdf' ! -path "$WIN_OUTPUT/*" -print0)

PDF_COUNT=$(find "$WSL_WORK" -type f -iname '*.pdf' | wc -l | tr -d ' ')
if [ "$PDF_COUNT" -eq 0 ]; then warn "✗ No PDFs found in workspace"; exit 1; fi
log "  ✓ $PDF_COUNT PDFs synced and ready"

log ""
log "[2/5] Extracting Text (Local CPU/GPU)..."
rm -f "$WSL_STATE/.ext_progress"
pids=()
while IFS= read -r -d '' pdf; do
  extract_document "$pdf" "$PDF_COUNT" &
  pids+=($!)
  while [ "${#pids[@]}" -ge "$EXTRACT_CONCURRENCY" ]; do
    if ! wait "${pids[0]}" 2>/dev/null; then :; fi
    pids=("${pids[@]:1}")
  done
done < <(find "$WSL_WORK" -type f -iname '*.pdf' -print0)
safe_wait_all "${pids[@]:-}" || true

if [ "$PIPELINE_MODE" != "oldexam_only" ]; then
  log ""
  log "[3/5] Generating Content (API)..."
  rm -f "$WSL_STATE/.api_progress"
  pids=()
  while IFS= read -r -d '' pdf; do
    process_api_document "$pdf" "$PDF_COUNT" &
    pids+=($!)
    while [ "${#pids[@]}" -ge "$API_CONCURRENCY" ]; do
      if ! wait "${pids[0]}" 2>/dev/null; then :; fi
      pids=("${pids[@]:1}")
    done
  done < <(find "$WSL_WORK" -type f -iname '*.pdf' -print0)
  safe_wait_all "${pids[@]:-}" || true

  log ""
  log "[4/5] Building Master Files per Category..."
  pids=()
  while IFS= read -r -d '' d; do
    process_master "$d" &
    pids+=($!)
    while [ "${#pids[@]}" -ge "$API_CONCURRENCY" ]; do
      if ! wait "${pids[0]}" 2>/dev/null; then :; fi
      pids=("${pids[@]:1}")
    done
  done < <(find "$WSL_OUTPUT" -type d -print0)
  safe_wait_all "${pids[@]:-}" || true
else
  log ""
  log "[3/5] Skipping Main Content API (Old Exams Only Mode)..."
  log ""
  log "[4/5] Skipping Master Compilation (Old Exams Only Mode)..."
fi

if [ "$PIPELINE_MODE" = "full" ] || [ "$PIPELINE_MODE" = "oldexam_only" ]; then
  log ""
  log "[5/5] Solving Old Exams for Anki (if any)..."
  pids=()
  while IFS= read -r -d '' pdf; do
    if [[ "$pdf" == *"/oldexams/"* ]]; then
      process_oldexam "$pdf" &
      pids+=($!)
      while [ "${#pids[@]}" -ge "$API_CONCURRENCY" ]; do
        if ! wait "${pids[0]}" 2>/dev/null; then :; fi
        pids=("${pids[@]:1}")
      done
    fi
  done < <(find "$WSL_WORK" -type f -iname '*.pdf' -print0)
  safe_wait_all "${pids[@]:-}" || true
else
  log ""
  log "[5/5] Skipping Old Exams Processing..."
fi

log ""
log "[Cleanup] Syncing back to Windows..."
while IFS= read -r -d '' file; do
  rel="${file#$WSL_OUTPUT/}"
  mkdir -p "$WIN_OUTPUT/$(dirname "$rel")"
  cp "$file" "$WIN_OUTPUT/$rel" || warn "  ✗ Failed to sync $file"
done < <(find "$WSL_OUTPUT" -type f \( -name '*.md' -o -name '*.csv' -o -name '*_solved.txt' \) -print0)

FAILED=$(find "$WSL_STATE" -name '*.failed' 2>/dev/null | wc -l | tr -d ' ' || echo 0)

log ""
log "╔══════════════════════════════════════╗"
log "║            Log Aggregation           ║"
log "╚══════════════════════════════════════╝"
LOG_COUNT=$(find "$WSL_STATE" -name '*.log' 2>/dev/null | wc -l | tr -d ' ' || echo 0)
if [ "$LOG_COUNT" -gt 0 ]; then
  grep -ihE "(✗|error|retry|failed|malformed)" "$WSL_STATE"/**/*.log 2>/dev/null || log "No major errors found in logs."
else
  log "No logs generated."
fi

log "╔══════════════════════════════════════╗"
log "║                Done                  ║"
log "╚══════════════════════════════════════╝"
log "Failed docs: $FAILED"
log "Output     : $WIN_OUTPUT"

if grep -qi microsoft /proc/version 2>/dev/null && command -v explorer.exe >/dev/null 2>&1; then
  explorer.exe "$(wslpath -w "$WIN_OUTPUT")" 2>/dev/null || true
fi

exit $([ "$FAILED" -eq 0 ] && echo 0 || echo 1)
