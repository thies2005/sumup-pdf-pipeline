# SumUp PDF Pipeline

Automated PDF-to-study pipeline for university material. It extracts text from PDFs, generates detailed study summaries, creates Anki flashcards, builds master summaries/decks per course, and can solve old exam papers into Anki-ready review files.

## Features

- Recursive PDF discovery from a Windows folder mounted in WSL
- Multiple extraction modes:
  - Native text extraction
  - Tesseract OCR
  - DocTR / Mindee OCR
- Multiple pipeline modes:
  - Full pipeline
  - Summary only
  - Anki only
  - Old exam only
- Anki card generation styles:
  - Atomic
  - Medium
  - Comprehensive
- Per-document retry handling and failure tracking
- Master summary generation per folder/course
- Master Anki deck generation per folder/course
- Old exam solving using course master summaries
- Syncs outputs back to Windows automatically

## Expected folder layout

Input is expected at:

```text
/mnt/c/Users/thies/Documents/sumup
```

Typical structure:

```text
sumup/
├── CourseA/
│   ├── lecture1.pdf
│   ├── lecture2.pdf
│   └── oldexams/
│       └── exam_2024.pdf
└── CourseB/
    └── notes.pdf
```

Generated working data is stored in WSL under:

```text
~/sumup/workspace
```

Final synced outputs go to:

```text
/mnt/c/Users/thies/Documents/sumup/summaries
```

## Requirements

- WSL on Windows
- Bash
- Python 3
- `opencode` CLI configured and available in PATH
- For native extraction fallback:
  - `pdftotext` from `poppler-utils`
- For Tesseract OCR mode:
  - `tesseract-ocr`
  - `poppler-utils`
- For DocTR OCR mode:
  - `libgl1`
  - Python packages installed by the script when needed

## Usage

Make it executable:

```bash
chmod +x sumup-pipeline.sh
```

Run normally:

```bash
./sumup-pipeline.sh
```

Dry run:

```bash
./sumup-pipeline.sh --dry-run
```

Clean workspace first:

```bash
./sumup-pipeline.sh --clean
```

Show help:

```bash
./sumup-pipeline.sh --help
```

## Pipeline outputs

Depending on the selected mode, the script generates:

- `*.md` detailed summaries
- `*.csv` Anki import files
- `MASTER_SUMMARY.md`
- `MASTER_ANKI.csv`
- `exam_ankis/*_solved.txt`

## Notes

- The script is designed around your WSL + Windows-mounted workflow.
- `oldexam_only` mode requires an existing `MASTER_SUMMARY.md` for each course.
- Failures are tracked via `.failed` marker files under the workspace state directory.
- Output generation uses model calls through `opencode run`.

## Repository contents

- `sumup-pipeline.sh` — main production-hardened Bash pipeline
- `README.md` — project overview and usage
