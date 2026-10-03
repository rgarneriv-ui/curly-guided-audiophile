"""Role Intel Drive folders + Google Docs endpoints for the gmail-webhook service.

Mount with:  app.include_router(roleintel.router)

Endpoints (all require the X-Api-Key header, compared against APP_API_KEY):
  POST /api/roleintel/folder
  POST /api/roleintel/doc/create
  GET  /api/roleintel/doc?docId=
  POST /api/roleintel/doc/write

Auth uses the OAuth user token in TOKEN_JSON_PATH (default token.json). The token
needs the `drive` and `documents` scopes.
"""
from __future__ import annotations

import base64
import datetime
import hmac
import io
import os
import re
from typing import Any, Optional

from fastapi import APIRouter, Depends, Header, HTTPException, Query
from pydantic import BaseModel, Field

FOLDER_MIME = "application/vnd.google-apps.folder"
DOC_MIME = "application/vnd.google-apps.document"
PARENT_PATH = ["Launch - Rob", "Applications"]
DEFAULT_SUBFOLDERS = ["Interview Prep", "Resume", "Role Intelligence"]
LOGO_NAME = "launch-logo.png"
LOGO_WIDTH_PT = 1.6 * 72
MAX_PREVIOUS_VERSIONS = 2

DATE = r"(\d{4}-\d{2}-\d{2}|unknown)"
META_RE = re.compile(rf"^(.*?) · {DATE}$")
H2_RE = re.compile(rf"^(AI Counsel|Previous version) · (.*?) · {DATE}( · on original)?$")

router = APIRouter(prefix="/api/roleintel")


# ---------------------------------------------------------------- auth / clients

def require_key(x_api_key: Optional[str] = Header(default=None)) -> None:
    expected = os.environ.get("APP_API_KEY", "")
    if not expected or not hmac.compare_digest(x_api_key or "", expected):
        raise HTTPException(status_code=401, detail="invalid api key")


def get_credentials():
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials

    creds = Credentials.from_authorized_user_file(os.environ.get("TOKEN_JSON_PATH", "token.json"))
    if not creds.valid and creds.refresh_token:
        creds.refresh(Request())
    return creds


def _services():
    # Built per request: googleapiclient's http objects are not thread-safe.
    from googleapiclient.discovery import build

    creds = get_credentials()
    drive = build("drive", "v3", credentials=creds, cache_discovery=False)
    docs = build("docs", "v1", credentials=creds, cache_discovery=False)
    return drive, docs


# ---------------------------------------------------------------- request models

class Version(BaseModel):
    model: str = ""
    at: str = ""
    text: str = ""


class Counsel(Version):
    target: str = ""


class Section(BaseModel):
    key: str = ""
    title: str
    versions: list[Version] = Field(default_factory=list)
    counsel: list[Counsel] = Field(default_factory=list)


class Brand(BaseModel):
    name: str = "launch."
    logoDataUrl: Optional[str] = None


class FolderReq(BaseModel):
    folderName: str
    subfolders: list[str] = Field(default_factory=lambda: list(DEFAULT_SUBFOLDERS))


class DocCreateReq(BaseModel):
    folderId: str
    title: str
    sections: list[Section]
    brand: Optional[Brand] = None


class DocWriteReq(BaseModel):
    docId: str
    sections: list[Section]


# ---------------------------------------------------------------- Drive helpers

def _q(value: str) -> str:
    return value.replace("\\", "\\\\").replace("'", "\\'")


def _find_folder(drive, name: str, parent: str) -> Optional[dict]:
    res = drive.files().list(
        q=f"name = '{_q(name)}' and mimeType = '{FOLDER_MIME}' and '{parent}' in parents and trashed = false",
        fields="files(id, name)", pageSize=1, orderBy="createdTime",
        supportsAllDrives=True, includeItemsFromAllDrives=True,
    ).execute()
    files = res.get("files", [])
    return files[0] if files else None


def _ensure_folder(drive, name: str, parent: str) -> tuple[str, bool]:
    found = _find_folder(drive, name, parent)
    if found:
        return found["id"], True
    created = drive.files().create(
        body={"name": name, "mimeType": FOLDER_MIME, "parents": [parent]},
        fields="id", supportsAllDrives=True,
    ).execute()
    return created["id"], False


_applications_id: Optional[str] = None


def applications_folder_id(drive) -> str:
    """APPLICATIONS_FOLDER_ID env, else resolve 'Launch - Rob' > 'Applications' once and cache."""
    global _applications_id
    if _applications_id:
        return _applications_id
    env = os.environ.get("APPLICATIONS_FOLDER_ID")
    if env:
        _applications_id = env
        return env
    parent = "root"
    for name in PARENT_PATH:
        found = _find_folder(drive, name, parent)
        if not found:
            raise HTTPException(500, f"Drive folder not found: {' > '.join(PARENT_PATH)} (missing '{name}')")
        parent = found["id"]
    _applications_id = parent
    return parent


def _folder_url(folder_id: str) -> str:
    return f"https://drive.google.com/drive/folders/{folder_id}"


def _doc_url(doc_id: str) -> str:
    return f"https://docs.google.com/document/d/{doc_id}/edit"


def _modified_time(drive, file_id: str) -> str:
    return drive.files().get(fileId=file_id, fields="modifiedTime", supportsAllDrives=True).execute()["modifiedTime"]


_logo_id: Optional[str] = None


def _ensure_logo(drive, data_url: str) -> str:
    """Upload the lockup once (cached by file ID / name), make it link-viewable, return a fetchable URL."""
    global _logo_id
    if not _logo_id:
        found = drive.files().list(
            q=f"name = '{LOGO_NAME}' and trashed = false and mimeType = 'image/png'",
            fields="files(id)", pageSize=1, supportsAllDrives=True, includeItemsFromAllDrives=True,
        ).execute().get("files", [])
        if found:
            _logo_id = found[0]["id"]
        else:
            from googleapiclient.http import MediaIoBaseUpload

            raw = base64.b64decode(data_url.split(",", 1)[1])
            media = MediaIoBaseUpload(io.BytesIO(raw), mimetype="image/png")
            _logo_id = drive.files().create(
                body={"name": LOGO_NAME}, media_body=media, fields="id", supportsAllDrives=True
            ).execute()["id"]
            drive.permissions().create(
                fileId=_logo_id, body={"type": "anyone", "role": "reader"}, supportsAllDrives=True
            ).execute()
    return f"https://drive.google.com/uc?export=view&id={_logo_id}"


# ---------------------------------------------------------------- rendering

def _u16(s: str) -> int:
    return len(s.encode("utf-16-le")) // 2


def _day(at: str) -> str:
    m = re.match(r"\d{4}-\d{2}-\d{2}", at or "")
    return m.group(0) if m else "unknown"


def render_section(sec: Section) -> list[tuple[str, str]]:
    """Blocks of (kind, text). Kinds: H1, META, BODY, H2."""
    blocks: list[tuple[str, str]] = [("H1", sec.title)]
    if sec.versions:
        latest = sec.versions[0]
        blocks += [("META", f"{latest.model} · {_day(latest.at)}"), ("BODY", latest.text)]
    for c in sec.counsel:
        suffix = " · on original" if c.target == "original" else ""
        blocks += [("H2", f"AI Counsel · {c.model} · {_day(c.at)}{suffix}"), ("BODY", c.text)]
    for v in sec.versions[1:1 + MAX_PREVIOUS_VERSIONS]:
        blocks += [("H2", f"Previous version · {v.model} · {_day(v.at)}"), ("BODY", v.text)]
    return blocks


def layout(blocks: list[tuple[str, str]], start: int, lead: str = "", tail: bool = True):
    """Return (text, spans). spans = [(kind, startIndex, endIndex)] in Docs UTF-16 indices.

    `lead` is inserted before the first block (not styled). With tail=False the final
    newline is left out of the text because the document already provides one.
    """
    parts: list[str] = []
    spans: list[tuple[str, int, int]] = []
    idx = start + _u16(lead)
    for kind, text in blocks:
        end = idx + _u16(text) + 1
        spans.append((kind, idx, end))
        parts.append(text + "\n")
        idx = end
    body = "".join(parts)
    if not tail:
        body = body[:-1]
    return lead + body, spans


_NAMED = {"TITLE": "TITLE", "H1": "HEADING_1", "H2": "HEADING_2"}


def style_requests(spans) -> list[dict]:
    reqs: list[dict] = []
    for kind, s, e in spans:
        rng = {"startIndex": s, "endIndex": e}
        reqs.append({"updateParagraphStyle": {
            "range": rng, "paragraphStyle": {"namedStyleType": _NAMED.get(kind, "NORMAL_TEXT")},
            "fields": "namedStyleType"}})
        if kind in _NAMED:  # headings keep their named-style text formatting
            continue
        reqs.append({"updateTextStyle": {
            "range": rng,
            "textStyle": {"italic": kind == "META", "bold": kind in ("BRAND", "LABEL")},
            "fields": "italic,bold"}})
    return reqs


def _insert(blocks, start: int, lead: str = "", tail: bool = True) -> list[dict]:
    text, spans = layout(blocks, start, lead, tail)
    return [{"insertText": {"location": {"index": start}, "text": text}}] + style_requests(spans)


# ---------------------------------------------------------------- doc reading

def _ptext(p: dict) -> str:
    runs = (e.get("textRun", {}).get("content", "") for e in p.get("elements", []))
    return "".join(runs).rstrip("\n")


def _pstyle(p: dict) -> str:
    return p.get("paragraphStyle", {}).get("namedStyleType", "NORMAL_TEXT")


def _is_italic(p: dict) -> bool:
    return any(e.get("textRun", {}).get("textStyle", {}).get("italic") for e in p.get("elements", []))


def parse_document(doc: dict) -> list[dict]:
    sections: list[dict] = []
    cur: Optional[dict] = None
    target: Optional[dict] = None
    first_after_h1 = False

    def start_target(store: list, entry: dict) -> dict:
        entry["_lines"] = []
        store.append(entry)
        return entry

    for el in doc.get("body", {}).get("content", []):
        p = el.get("paragraph")
        if not p:
            continue
        style, text = _pstyle(p), _ptext(p)
        if style == "HEADING_1":
            cur = {"title": text, "versions": [], "counsel": []}
            sections.append(cur)
            target, first_after_h1 = None, True
            continue
        if cur is None:  # brand, title and TOC above the first section
            continue
        m = H2_RE.match(text) if style == "HEADING_2" else None
        if m:
            kind, model, at, on_orig = m.groups()
            at = "" if at == "unknown" else at
            if kind == "AI Counsel":
                target = start_target(cur["counsel"], {"model": model, "at": at, "target": "original" if on_orig else ""})
            else:
                target = start_target(cur["versions"], {"model": model, "at": at})
        elif first_after_h1 and _is_italic(p) and META_RE.match(text):
            model, at = META_RE.match(text).groups()
            target = start_target(cur["versions"], {"model": model, "at": "" if at == "unknown" else at})
        else:
            if target is None:
                if not text.strip():
                    first_after_h1 = False
                    continue
                target = start_target(cur["versions"], {"model": "", "at": ""})
            target["_lines"].append(text)
        first_after_h1 = False

    for sec in sections:
        for entry in sec["versions"] + sec["counsel"]:
            entry["text"] = "\n".join(entry.pop("_lines")).strip("\n")
    return sections


# ---------------------------------------------------------------- TOC

def _paragraphs(doc: dict) -> list[dict]:
    return [el for el in doc.get("body", {}).get("content", []) if "paragraph" in el]


def refresh_toc(docs, doc_id: str) -> None:
    """Rewrite the 'Contents' list from the current H1s and link each entry to its heading."""
    doc = docs.documents().get(documentId=doc_id).execute()
    paras = _paragraphs(doc)
    label = next((i for i, el in enumerate(paras) if _ptext(el["paragraph"]) == "Contents"
                  and _pstyle(el["paragraph"]) == "NORMAL_TEXT"), None)
    h1_idx = next((i for i, el in enumerate(paras) if _pstyle(el["paragraph"]) == "HEADING_1"), None)
    if label is None or h1_idx is None or h1_idx <= label:
        return
    toc_start = paras[label]["endIndex"]
    toc_end = paras[h1_idx]["startIndex"]
    titles = [_ptext(el["paragraph"]) for el in paras if _pstyle(el["paragraph"]) == "HEADING_1"]
    reqs: list[dict] = []
    if toc_end > toc_start:
        reqs.append({"deleteContentRange": {"range": {"startIndex": toc_start, "endIndex": toc_end}}})
    reqs += _insert([("TOC", t) for t in titles], toc_start)
    docs.documents().batchUpdate(documentId=doc_id, body={"requests": reqs}).execute()

    doc = docs.documents().get(documentId=doc_id).execute()
    paras = _paragraphs(doc)
    heading_ids = [el["paragraph"]["paragraphStyle"].get("headingId") for el in paras
                   if _pstyle(el["paragraph"]) == "HEADING_1"]
    label = next(i for i, el in enumerate(paras) if _ptext(el["paragraph"]) == "Contents")
    links = []
    for k, hid in enumerate(heading_ids):
        el = paras[label + 1 + k]
        end = el["endIndex"] - 1  # leave the paragraph mark unlinked
        if hid and end > el["startIndex"]:
            links.append({"updateTextStyle": {
                "range": {"startIndex": el["startIndex"], "endIndex": end},
                "textStyle": {"link": {"headingId": hid}}, "fields": "link"}})
    if links:
        docs.documents().batchUpdate(documentId=doc_id, body={"requests": links}).execute()


# ---------------------------------------------------------------- endpoints

@router.post("/folder", dependencies=[Depends(require_key)])
def create_folder(req: FolderReq):
    drive, _ = _services()
    parent = applications_folder_id(drive)
    folder_id, existed = _ensure_folder(drive, req.folderName, parent)
    subs = {}
    for name in req.subfolders:
        sub_id, _existed = _ensure_folder(drive, name, folder_id)
        subs[name] = {"id": sub_id, "url": _folder_url(sub_id)}
    return {"folderId": folder_id, "folderUrl": _folder_url(folder_id), "existed": existed, "subfolders": subs}


@router.post("/doc/create", dependencies=[Depends(require_key)])
def create_doc(req: DocCreateReq):
    drive, docs = _services()
    doc_id = drive.files().create(
        body={"name": req.title, "mimeType": DOC_MIME, "parents": [req.folderId]},
        fields="id", supportsAllDrives=True,
    ).execute()["id"]

    logo_url = None
    if req.brand and req.brand.logoDataUrl:
        logo_url = _ensure_logo(drive, req.brand.logoDataUrl)
    brand_text = "" if logo_url else (req.brand.name if req.brand else "launch.")

    blocks: list[tuple[str, str]] = [("BRAND", brand_text), ("TITLE", req.title), ("LABEL", "Contents")]
    for sec in req.sections:
        blocks += render_section(sec)

    reqs: list[dict] = [{"updateDocumentStyle": {
        "documentStyle": {"documentFormat": {"documentMode": "PAGELESS"}},
        "fields": "documentFormat.documentMode"}}]
    reqs += _insert(blocks, 1, tail=False)
    if logo_url:  # last, so earlier indices are unaffected; lands in the empty brand paragraph
        reqs.append({"insertInlineImage": {
            "location": {"index": 1}, "uri": logo_url,
            "objectSize": {"width": {"magnitude": LOGO_WIDTH_PT, "unit": "PT"}}}})
    docs.documents().batchUpdate(documentId=doc_id, body={"requests": reqs}).execute()
    refresh_toc(docs, doc_id)
    return {"docId": doc_id, "docUrl": _doc_url(doc_id), "modifiedTime": _modified_time(drive, doc_id)}


@router.get("/doc", dependencies=[Depends(require_key)])
def read_doc(docId: str = Query(...)):
    drive, docs = _services()
    doc = docs.documents().get(documentId=docId).execute()
    return {"modifiedTime": _modified_time(drive, docId), "sections": parse_document(doc)}


@router.post("/doc/write", dependencies=[Depends(require_key)])
def write_doc(req: DocWriteReq):
    drive, docs = _services()
    for sec in req.sections:  # one at a time: indices shift after every replacement
        doc = docs.documents().get(documentId=req.docId).execute()
        paras = _paragraphs(doc)
        doc_end = doc["body"]["content"][-1]["endIndex"] - 1
        h1s = [(_ptext(el["paragraph"]), el["startIndex"]) for el in paras
               if _pstyle(el["paragraph"]) == "HEADING_1"]
        pos = next((i for i, (title, _) in enumerate(h1s) if title == sec.title), None)
        blocks = render_section(sec)
        if pos is None:  # new section: append
            reqs = _insert(blocks, doc_end, lead="\n", tail=False)
        else:
            start = h1s[pos][1]
            end = h1s[pos + 1][1] if pos + 1 < len(h1s) else doc_end
            last = end == doc_end
            reqs = []
            if end > start:
                reqs.append({"deleteContentRange": {"range": {"startIndex": start, "endIndex": end}}})
            reqs += _insert(blocks, start, tail=not last)
        docs.documents().batchUpdate(documentId=req.docId, body={"requests": reqs}).execute()
    refresh_toc(docs, req.docId)
    return {"modifiedTime": _modified_time(drive, req.docId)}
