"""Differential check of SendmailCore's MIME parse against CPython's email package.

Usage: python3 -I differential.py --dump PATH/TO/sendmail-test
       --corpus DIR [--corpus DIR ...] [--expected FILE] [--show-all]

Each --corpus DIR is a root whose messages are named by their path below it
(e.g. `cpython/msg_33.txt`); the names must be unique across roots.

`sendmail-test --parse-dump FILE...` prints SendmailCore's view of each corpus
message. This script parses the same bytes with `email.policy.default`,
selects body and attachment parts by SendmailCore's own rules (so only the
MIME decoding is compared, not the product's part-selection policy), and
reports every field where the two disagree. Each divergence must be listed
under a classified finding in expected-divergences.json; an unlisted
divergence, or a listed one that no longer occurs, fails the run.

It also re-parses the .eml that EmlBuilder writes for each message and checks
that Python reads back the same To/Cc/Bcc mailboxes SendmailCore parsed.
"""

import argparse
import base64
import json
import subprocess
import sys
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
from pathlib import Path

HERE = Path(__file__).resolve().parent
CORPUS_SUFFIXES = {".eml", ".txt"}
ADDRESS_FIELDS = ("to", "cc", "bcc")
CLASSES = {
    "ours-bug": "SendmailCore disagrees with the spec; fix it",
    "python-quirk": "Python's email package is lenient or wrong; the spec is on our side",
    "intentional": "SendmailCore's behavior is a deliberate repo decision",
}


def corpus_files(corpus_dirs):
    """Map each message's name (its path below its corpus root) to its path."""
    files = {}
    for corpus_dir in corpus_dirs:
        for path in corpus_dir.resolve().rglob("*"):
            if not path.is_file() or path.suffix not in CORPUS_SUFFIXES:
                continue
            relative = path.relative_to(corpus_dir.resolve()).as_posix()
            if relative in files:
                raise SystemExit(f"{relative} is in more than one corpus directory")
            files[relative] = path
    return dict(sorted(files.items()))


def run_dump(dump_binary, files):
    completed = subprocess.run(
        [str(dump_binary), "--parse-dump", *map(str, files)],
        check=True,
        capture_output=True,
    )
    return json.loads(completed.stdout)


def parse_reference(data):
    return BytesParser(policy=policy.default).parsebytes(data)


def unescape_raw_utf8(text):
    """BytesParser keeps raw 8-bit header bytes (RFC 6532) as surrogate
    escapes; turn them back into the UTF-8 text they encode."""
    return text.encode("utf-8", "surrogateescape").decode("utf-8", "replace")


def header_text(message, name):
    value = message.get(name)
    return "" if value is None else unescape_raw_utf8(str(value))


def mailboxes(message, name):
    found = []
    for header in message.get_all(name) or []:
        for address in header.addresses:
            found.append({
                "name": unescape_raw_utf8(address.display_name) or None,
                "address": unescape_raw_utf8(address.addr_spec),
            })
    return found


def leaf_parts(part):
    if part.get_content_maintype() != "multipart":
        yield part
        return
    payload = part.get_payload()
    if isinstance(payload, list):
        for subpart in payload:
            yield from leaf_parts(subpart)


def text_content(part):
    try:
        return part.get_content()
    except LookupError:
        payload = part.get_payload(decode=True) or b""
        return payload.decode("utf-8", "replace")


def decoded_bytes(part):
    """Transfer-decoded content, or None for a message/* part, whose payload
    Python holds as a parsed Message rather than bytes."""
    if part.get_content_maintype() == "message":
        return None
    return part.get_payload(decode=True) or b""


def reference_body_and_attachments(message):
    """Mirror MIMEParser's part selection, using Python's MIME decoding."""
    body = None
    body_slot_filled = False
    html = None
    attachments = []
    if message.get_content_maintype() != "multipart":
        if message.get_content_maintype() != "text":
            return {"body": None, "html": None, "attachments": []}
        content = text_content(message)
        if message.get_content_type() == "text/html":
            return {"body": None, "html": content, "attachments": []}
        return {"body": content, "html": None, "attachments": []}

    for part in leaf_parts(message):
        content_type = part.get_content_type()
        filename = part.get_filename()
        disposition = part.get_content_disposition()
        is_attachment = (
            disposition == "attachment"
            or filename is not None
            or not content_type.startswith("text/")
        )
        if not is_attachment:
            content = text_content(part)
            if content_type == "text/html" and html is None:
                html = content
            if not body_slot_filled and content != "":
                body_slot_filled = True
                if content_type != "text/html":
                    body = content
            continue
        if disposition == "inline" and filename is None:
            continue
        attachments.append({
            "filename": filename if filename is not None else f"attachment-{len(attachments) + 1}.bin",
            "content": decoded_bytes(part),
        })
    return {
        "body": body,
        "html": html,
        "attachments": attachments,
    }


def reference_view(data):
    message = parse_reference(data)
    view = {"subject": header_text(message, "subject")}
    senders = mailboxes(message, "from")
    view["from"] = senders[0] if senders else None
    for field in ADDRESS_FIELDS:
        view[field] = mailboxes(message, field)
    view.update(reference_body_and_attachments(message))
    return view


def normalized_mailbox(mailbox):
    if mailbox is None:
        return None
    return {"name": mailbox.get("name") or None, "address": mailbox["address"]}


def compare(ours, reference):
    """Yield (field, ours, reference) for every field that disagrees."""
    if ours["subject"] != reference["subject"]:
        yield "subject", ours["subject"], reference["subject"]
    if normalized_mailbox(ours["from"]) != normalized_mailbox(reference["from"]):
        yield "from", ours["from"], reference["from"]
    for field in ADDRESS_FIELDS:
        our_list = [normalized_mailbox(m) for m in ours[field]]
        reference_list = [normalized_mailbox(m) for m in reference[field]]
        if our_list != reference_list:
            yield field, our_list, reference_list
    if reference["body"] is not None and ours["body"] != reference["body"]:
        yield "body", ours["body"], reference["body"]
    if ours["html"] != reference["html"]:
        yield "html", ours["html"], reference["html"]
    our_attachments = [
        {"filename": a["filename"], "content": base64.b64decode(a["base64"])} for a in ours["attachments"]
    ]
    if not attachments_agree(our_attachments, reference["attachments"]):
        yield "attachments", summarize(our_attachments), summarize(reference["attachments"])

    rebuilt = parse_reference(base64.b64decode(ours["rebuiltEmlBase64"]))
    for field in ADDRESS_FIELDS:
        our_list = [normalized_mailbox(m) for m in ours[field]]
        reparsed = [normalized_mailbox(m) for m in mailboxes(rebuilt, field)]
        if our_list != reparsed:
            yield f"rebuilt-eml.{field}", our_list, reparsed


def attachments_agree(ours, reference):
    if [a["filename"] for a in ours] != [a["filename"] for a in reference]:
        return False
    return all(
        theirs["content"] is None or mine["content"] == theirs["content"]
        for mine, theirs in zip(ours, reference)
    )


def summarize(attachments):
    return [
        {
            "filename": a["filename"],
            "content": None if a["content"] is None else a["content"][:60].decode("utf-8", "replace"),
            "bytes": None if a["content"] is None else len(a["content"]),
        }
        for a in attachments
    ]


def load_expected(path):
    """Map (file, field) to its finding. Each finding in the file groups the
    cases ("FILE FIELD") that one root cause explains."""
    expected = {}
    for finding in json.loads(path.read_text())["findings"]:
        if finding["class"] not in CLASSES:
            raise ValueError(f"finding {finding['id']}: class must be one of {sorted(CLASSES)}")
        for case in finding["cases"]:
            relative, field = case.rsplit(" ", 1)
            if (relative, field) in expected:
                raise ValueError(f"case {case!r} is listed under two findings")
            expected[(relative, field)] = finding
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dump", required=True, type=Path, help="path to the built sendmail-test executable")
    parser.add_argument(
        "--corpus", type=Path, action="append", required=True,
        help="a corpus root; repeat for the repo's corpus and the fetched one",
    )
    parser.add_argument("--expected", type=Path, default=HERE / "expected-divergences.json")
    parser.add_argument("--show-all", action="store_true", help="print expected divergences too")
    parser.add_argument(
        "--emit-unexpected", action="store_true",
        help="also print unexpected divergences as JSON case strings, for pasting into a finding",
    )
    args = parser.parse_args()

    files = corpus_files(args.corpus)
    dump = run_dump(args.dump, files.values())
    expected = load_expected(args.expected)

    seen = set()
    unexpected = []
    for relative, path in files.items():
        ours = dump[str(path)]
        if "error" in ours:
            unexpected.append((relative, "parse", ours["error"], None))
            continue
        try:
            reference = reference_view(path.read_bytes())
        except Exception as error:  # noqa: BLE001 -- a reference crash is itself a finding
            unexpected.append((relative, "reference-error", None, repr(error)))
            continue
        for field, our_value, reference_value in compare(ours, reference):
            key = (relative, field)
            seen.add(key)
            entry = expected.get(key)
            if entry is None:
                unexpected.append((relative, field, our_value, reference_value))
            elif args.show_all:
                print(f"EXPECTED ({entry['class']}) {entry['id']}: {relative} {field}")
                print(f"    ours:   {json.dumps(our_value, ensure_ascii=False)}")
                print(f"    python: {json.dumps(reference_value, ensure_ascii=False)}")

    stale = sorted(set(expected) - seen)
    for relative, field, our_value, reference_value in unexpected:
        print(f"UNEXPECTED {relative} {field}")
        print(f"    ours:   {json.dumps(our_value, ensure_ascii=False)}")
        print(f"    python: {json.dumps(reference_value, ensure_ascii=False)}")
    for relative, field in stale:
        print(f"STALE expected divergence no longer occurs: {relative} {field}")
    if args.emit_unexpected and unexpected:
        print(json.dumps([f"{relative} {field}" for relative, field, _, _ in unexpected], indent=2))

    print(
        f"{len(files)} messages, {len(seen & expected.keys())} expected divergences, "
        f"{len(unexpected)} unexpected, {len(stale)} stale"
    )
    return 1 if unexpected or stale else 0


if __name__ == "__main__":
    sys.exit(main())
