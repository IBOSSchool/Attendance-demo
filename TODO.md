# iSAMS Attendance & Parent Notification Platform

## Goal
Build an admin platform that:
- Pulls attendance/register data from iSAMS (read + write where allowed)
- Identifies absentees (daily + date-range filters)
- Notifies parents/guardians via SMS/email
- Tracks delivery status + audit logs
- Provides an admin panel for operations

## What “My Classes” Means (Data Model)
- Teaching Sets / Teaching Groups (who teaches what)
- Timetable Events (what happens today/this week)
- Register Sessions + Attendance Marks (present/absent/late + codes)

---

# Epic 0 — Access, Infrastructure, and Project Bootstrap (Phase 0)

## Deliverables
- Batch API Key(s): Development + Production
- REST API access: Client credentials + required scopes/permissions
- Access to Developer Portal / API Explorer for testing
- Repository scaffold: backend + db + cache + worker-ready structure
- Docker Compose stack for local dev (Postgres + Redis + API)
- `.env.example` + Phase 0 checklist docs

## Admin Checklist
- [ ] Confirm **API Services Manager** is enabled in iSAMS Control Panel
- [ ] Create **Batch API Key (Dev)**: Control Panel → API Services Manager → Manage Batch API Keys → Create Batch API Key
- [ ] Create **Batch API Key (Prod)** once MVP is ready
- [ ] Obtain/enable **REST API** credentials (Client ID/Secret) + required access to Student Registers endpoints
- [ ] Confirm iSAMS host/domain (often `*.isams.cloud`)
- [ ] Decide notification channel(s): SMS/email provider used by *your* platform (recommended) vs internal iSAMS comms
- [ ] Security baseline: no secrets in git; use env vars / secret manager; enable audit logging

---

# Epic 1 — MVP Product

## Roles
- [ ] Admin
- [ ] Attendance Officer
- [ ] Teacher (optional for MVP)

## Core Flows
- [ ] View classes/teaching groups
- [ ] View today’s registers/sessions
- [ ] Compute absences (filters by date/class/year group)
- [ ] Notify parents (preview → send)
- [ ] Track notification lifecycle (queued/sent/failed/retry)
- [ ] Export reports (CSV)

## Notification Rules
- [ ] Anti-spam: one message per student per time window
- [ ] Templates (SMS/email) with variables (student name, date, period, class)
- [ ] Error handling + retries + dead-letter

---

# Epic 2 — Technical Architecture

- [ ] Services:
  - [ ] iSAMS Integration Service (Batch + REST)
  - [ ] Core Platform API (your API)
  - [ ] Queue/Worker (sync + notification sending)
  - [ ] Admin Frontend Panel
- [ ] Internal API contract (OpenAPI)
- [ ] Data strategy: cache-only vs full mirror + sync
- [ ] Security: RBAC, audit logs, secret handling, rate limiting

---

# Epic 3 — Database & Schema

## Proposed Tables
- [ ] users, roles, audit_logs
- [ ] students
- [ ] contacts (parents/guardians)
- [ ] student_contact_links
- [ ] teaching_sets
- [ ] timetable_events
- [ ] register_sessions
- [ ] attendance_marks
- [ ] notifications
- [ ] notification_recipients
- [ ] notification_attempts

## Sync Strategy
- [ ] Nightly Batch sync for “slow-changing” entities (students/contacts/teaching sets)
- [ ] REST for real-time registers/marks/absences

---

# Epic 4 — Backend (Platform API)

## Proposed Endpoints
- [ ] GET /health
- [ ] GET /classes
- [ ] GET /registers/today
- [ ] GET /absences?date=YYYY-MM-DD
- [ ] POST /notify/absent-parents
- [ ] GET /audit

## Non-functional
- [ ] retries/backoff
- [ ] rate limiting
- [ ] structured logs + tracing

---

# Epic 5 — Admin Frontend

- [ ] Today dashboard: classes + sessions + absence counters
- [ ] Absences page: filters + export
- [ ] Notify page: audience selection + template + preview + send
- [ ] Logs page: status, errors, retry controls

---

# Epic 6 — Testing & Deployment

- [ ] Docker Compose: db + redis + api + worker + frontend
- [ ] Integration tests against iSAMS sandbox/staging
- [ ] Monitoring/alerting
- [ ] DB backups + migrations
- [ ] Runbook
