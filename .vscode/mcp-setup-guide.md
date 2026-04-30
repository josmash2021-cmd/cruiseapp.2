# CruiseApp MCP Servers Setup Guide

## Overview

Your CruiseApp uses **ONE database**: **Supabase PostgreSQL** (production).  
Local development uses SQLite, but all production data lives in Supabase.

| MCP Server | Purpose | Status |
|-----------|---------|--------|
| **Supabase (PostgreSQL)** | Production database queries | ✅ Configured |
| **Stripe** | Payment processing | ✅ Configured |
| **Filesystem** | Project file access | ✅ Configured |

**Not Available:** Firebase/Firestore MCP (Google hasn't released one).

---

## 1. Supabase MCP Server

### What It Does
- Query your production Supabase PostgreSQL database
- Read table schemas, indexes, relationships
- Execute SELECT queries (read-only by default)
- Analyze query performance

### Your Supabase Connection

```
Project: cruise-ride-db
Ref: elvszwazwvpgqvnzxwnq
URL: postgresql://postgres.elvszwazwvpgqvnzxwnq@aws-1-us-east-2.pooler.supabase.com:5432/postgres
```

### Prerequisites

1. **Get your Supabase password** from your Supabase dashboard:
   - Go to: https://supabase.com/dashboard/project/elvszwazwvpgqvnzxwnq/settings/database
   - Copy the password for user `postgres`

2. **Set environment variable** in PowerShell:

   ```powershell
   [System.Environment]::SetEnvironmentVariable("SUPABASE_DB_PASSWORD", "tu-password-aqui", "User")
   ```

3. **Restart VS Code** after setting the variable.

### Test Connection

Ask Kimi:
```
List all tables in the database
```

Or:
```
Show me the schema of the users table
```

### Example Queries for CruiseApp

**Query 1: Top earning drivers this week**
```
Query the trips table to find the top 10 drivers by total earnings in the last 7 days.
```

**Query 2: Pending driver applications**
```
Show me all drivers with verification_status = 'pending', ordered by application date.
```

**Query 3: Failed payments**
```
Find riders with failed payment attempts in the last 30 days.
```

---

## 2. Stripe MCP Server

### Prerequisites

1. **Get your Stripe Secret Key** from: https://dashboard.stripe.com/apikeys
2. **Set environment variable**:
   ```powershell
   [System.Environment]::SetEnvironmentVariable("STRIPE_SECRET_KEY", "sk_test_tu_key_aqui", "User")
   ```
3. **Restart VS Code**.

### Test Connection

Ask Kimi:
```
List the last 10 payments from Stripe
```

---

## 3. Filesystem MCP Server

Already configured to access `c:\Users\Puma\cruiseapp.2`.

---

## Security

- ✅ `.env` is in `.gitignore`
- ✅ `.vscode/settings.json` uses `${env:VARIABLE}` (no hardcoded secrets)
- ✅ `.env.example` shows format without real values
- ⚠️ **NEVER** commit `.env` or `settings.local.json`

---

## Troubleshooting

### MCP Server Not Starting
1. Check Node.js: `node --version` (needs v18+)
2. Restart VS Code after setting env variables

### Supabase Connection Failed
```
Error: password authentication failed
```
- Verify `SUPABASE_DB_PASSWORD` is set correctly
- Check if IP is allowlisted in Supabase Dashboard → Database → IPv4

### Kimi Code Not Recognizing MCP
1. `Ctrl+Shift+P` → `Kimi Code: Reload Window`
2. Check MCP status in Kimi Code panel
