#!/usr/bin/env python3
"""
Automated AI Release Notes Generator for GitHub Actions CI/CD.
Synthesizes git commit history into structured, professional, concise
GitHub Release Notes in English using Google Gemini Interactions API.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

MODELS_FALLBACK_CHAIN = [
    "gemini-3.8-flash",
    "gemini-3.7-flash",
    "gemini-3.6-flash",
    "gemini-3.5-flash",
    "gemini-3.5-flash-lite",
    "gemini-3.1-flash-lite",
]

INTERACTIONS_API_URL = "https://generativelanguage.googleapis.com/v1beta/interactions"
API_REVISION = "2026-05-20"


def clean_markdown_fences(text: str) -> str:
    """Removes surrounding markdown backtick blocks if LLM encloses entire response in ```markdown."""
    trimmed = text.strip()
    has_opening_fence = False
    if trimmed.startswith("```markdown"):
        trimmed = trimmed[len("```markdown"):].strip()
        has_opening_fence = True
    elif trimmed.startswith("```md"):
        trimmed = trimmed[len("```md"):].strip()
        has_opening_fence = True
    elif trimmed.startswith("```"):
        trimmed = trimmed[3:].strip()
        has_opening_fence = True

    if has_opening_fence and trimmed.endswith("```"):
        trimmed = trimmed[:-3].strip()
    return trimmed


def extract_output_text(response_data: dict) -> str:
    """Extracts text content from the Interactions API response resource."""
    # 1. Check direct output_text if exposed
    if "output_text" in response_data and isinstance(response_data["output_text"], str):
        text = response_data["output_text"].strip()
        if text:
            return text

    # 2. Extract from execution steps: step.type == 'model_output' -> content[].text
    steps = response_data.get("steps", [])
    collected_texts = []
    for step in steps:
        if step.get("type") == "model_output":
            for block in step.get("content", []):
                if isinstance(block, dict) and block.get("type") == "text":
                    collected_texts.append(block.get("text", ""))

    if collected_texts:
        return "".join(collected_texts).strip()

    return ""


def generate_notes_with_interactions_api(
    commits_log: str, tag_name: str, prev_notes: str, api_key: str
) -> str:
    system_instruction = (
        "You are an expert technical release engineer for Lumen (a cross-platform electricity outage monitoring application for Ukraine). "
        "Your task is to synthesize raw git commits into clean, professional, concise, and beautifully structured "
        "GitHub Release Notes in Ukrainian.\n\n"
        "Formatting Guidelines:\n"
        "- Tone: Professional, restrained, developer-oriented, minimalist, suitable for official GitHub releases in Ukrainian.\n"
        "- All release notes MUST be written in Ukrainian.\n"
        "- Group changes into clear logical sections with emojis, for example:\n"
        "  ### 🚀 Нові можливості\n"
        "  ### ⚡ Покращення та швидкодія\n"
        "  ### 🐛 Виправлені помилки\n"
        "  ### 🧹 Технічні зміни та оптимізація\n"
        "  (Include only sections that have actual relevant changes).\n"
        "- Synthesize multiple related commits into coherent, impactful bullet points with context and rationale in Ukrainian.\n"
        "- Do NOT invent or hallucinate features that are not explicitly documented in the commit log.\n"
        "- Do NOT include a 'Full Changelog' line or URL (it is appended automatically by the CI workflow).\n"
        "- Do NOT enclose the entire output in triple backticks (```markdown)."
    )

    prompt_parts = [
        f"Release Version: {tag_name}",
    ]

    if prev_notes and len(prev_notes.strip()) > 30:
        prompt_parts.append(
            f"--- Style Reference (Previous Release Notes) ---\n{prev_notes.strip()[:2000]}"
        )

    prompt_parts.append(
        f"--- Git Commit History (Range for this release) ---\n{commits_log.strip()}"
    )
    prompt_parts.append("Generate the final release notes for this version in Ukrainian:")

    prompt = "\n\n".join(prompt_parts)

    for model_name in MODELS_FALLBACK_CHAIN:
        print(f"Attempting generation with model: {model_name}...")
        headers = {
            "x-goog-api-key": api_key,
            "Content-Type": "application/json",
            "Api-Revision": API_REVISION,
        }

        payload = {
            "model": model_name,
            "input": prompt,
            "system_instruction": system_instruction,
            "generation_config": {
                "temperature": 1.0,
                "max_output_tokens": 65536,
            },
        }

        try:
            req = urllib.request.Request(
                INTERACTIONS_API_URL,
                data=json.dumps(payload).encode("utf-8"),
                headers=headers,
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=60) as response:
                res_data = json.loads(response.read().decode("utf-8"))
                output = extract_output_text(res_data)
                if output:
                    print(f"Successfully generated release notes via Interactions API ({model_name}).")
                    return clean_markdown_fences(output)
        except urllib.error.HTTPError as err:
            error_body = err.read().decode("utf-8", errors="replace")
            print(
                f"Model {model_name} HTTP {err.code}: {error_body[:250]}",
                file=sys.stderr,
            )
            # Proceed to next model in fallback chain with a brief backoff
            time.sleep(1.5)
            continue
        except Exception as err:
            print(f"Model {model_name} request error: {err}", file=sys.stderr)
            time.sleep(1.5)
            continue

    return ""


def main():
    commits_file = sys.argv[1] if len(sys.argv) > 1 else "commits_log.txt"
    prev_notes_file = sys.argv[2] if len(sys.argv) > 2 else "prev_notes.txt"
    output_file = sys.argv[3] if len(sys.argv) > 3 else "AI_RELEASE_NOTES.md"

    # Support reading from environment or local .env if available
    api_key = os.environ.get("GEMINI_API_KEY", "").strip()
    if not api_key and os.path.isfile(".agents/.env"):
        try:
            with open(".agents/.env", "r", encoding="utf-8") as f:
                for line in f:
                    if line.startswith("GEMINI_API_KEY="):
                        api_key = line.split("=", 1)[1].strip().strip("'\"")
                        break
        except Exception:
            pass

    tag_name = os.environ.get("TAG_NAME", "Release").strip()

    if not api_key:
        print("Notice: GEMINI_API_KEY is not set. Skipping AI release notes generation.")
        return

    if not os.path.isfile(commits_file):
        print(f"Notice: Commits file '{commits_file}' not found. Skipping.")
        return

    with open(commits_file, "r", encoding="utf-8", errors="replace") as f:
        commits_log = f.read().strip()

    if not commits_log:
        print("Notice: Commits log is empty. Skipping.")
        return

    prev_notes = ""
    if os.path.isfile(prev_notes_file):
        with open(prev_notes_file, "r", encoding="utf-8", errors="replace") as f:
            prev_notes = f.read().strip()

    print(
        f"Generating AI release notes for tag '{tag_name}' ({len(commits_log)} chars of commit logs)..."
    )
    notes = generate_notes_with_interactions_api(commits_log, tag_name, prev_notes, api_key)

    if notes:
        with open(output_file, "w", encoding="utf-8") as f:
            f.write(notes + "\n")
        print(f"Generated release notes written to: {output_file}")
    else:
        print("Warning: All models in fallback chain failed. Standard fallback notes will be used.")


if __name__ == "__main__":
    main()
