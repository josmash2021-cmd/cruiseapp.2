# CruiseApp MCP Servers Setup Guide

## Overview

This guide configures **3 MCP servers** for your CruiseApp ride-sharing project:

| Priority | MCP Server | Purpose | Status |
|----------|-----------|---------|--------|
| 🔴 High | **Supabase (PostgreSQL)** | Production database queries | ✅ Available |
| 🟡 Medium | **Stripe** | Payment processing | ✅ Available |
| ⚪ Low | **Firebase/Firestore** | Auth, FCM, Analytics | ❌ Not available as MCP |

---

## 1. PostgreSQL MCP Server (Railway Production)

### What It Does
- Query your production PostgreSQL database on Railway
- Read table schemas, indexes, relationships
- Execute SELECT queries (read-only by default)
- Analyze query performance

### Prerequisites

1. **Get your Railway Database URL** from Railway Dashboard:
   - Go to: https://railway.app/project/cruiseapp.2
   - Click on your PostgreSQL service → Variables
   - Copy the `DATABASE_URL` value
   
   It looks like:
   ```
   postgresql://postgres:PASSWORD@containers-xxx.railway.app:1234/railway
   ```

2. **Set environment variable** (choose ONE method):

   **Option A: Windows System Environment Variable (Recommended)**
   ```powershell
   [System.Environment]::SetEnvironmentVariable("DATABASE_URL", "postgresql://postgres:PASSWORD@containers-xxx.railway.app:1234/railway", "User")
   ```
   Then restart VS Code.

   **Option B: .env file in project root**
   Create `c:\Users\Puma\cruiseapp.2\.env`:
   ```
   DATABASE_URL=postgresql://postgres:PASSWORD@containers-xxx.railway.app:1234/railway
   STRIPE_SECRET_KEY=sk_test_... or sk_live_...
   ```
   
   **Option C: Direct in settings.json (NOT recommended for production)**
   Replace `"${env:DATABASE_URL}"` with your actual URL.

### Alternative: Supabase PostgreSQL

If your Railway app actually connects to Supabase instead of Railway PostgreSQL:

1. Uncomment the `cruiseapp-supabase` section in `.vscode/settings.json`
2. Set your Supabase password:
   ```powershell
   [System.Environment]::SetEnvironmentVariable("SUPABASE_DB_PASSWORD", "your-supabase-password", "User")
   ```

### Test Connection

After setting the URL, open Kimi Code in VS Code and ask:

```
List all tables in the database
```

Or:

```
Show me the schema of the users table
```

### Example Queries for CruiseApp

**Query 1: Find top earning drivers this week**
```
Query the trips table to find the top 10 drivers by total earnings in the last 7 days, including their name, trip count, and average rating.
```

**Query 2: Analyze pending driver applications**
```
Show me all drivers with verification_status = 'pending', ordered by application date. Include their vehicle info and background check status.
```

**Query 3: Find riders with failed payments**
```
Query payments and trips to find riders who had failed payment attempts in the last 30 days, with their trip history and total amount owed.
```

---

## 2. Stripe MCP Server

### What It Does
- Manage customers, payments, refunds
- View invoices and subscriptions
- Analyze payment failures and disputes
- Create/test payment intents

### Prerequisites

1. **Get your Stripe Secret Key** from Stripe Dashboard:
   - Go to: https://dashboard.stripe.com/apikeys
   - Copy your `sk_test_...` (test) or `sk_live_...` (production) key

2. **Set environment variable**:

   **Option A: Windows System Environment Variable**
   ```powershell
   [System.Environment]::SetEnvironmentVariable("STRIPE_SECRET_KEY", "sk_test_your_key_here", "User")
   ```
   Then restart VS Code.

   **Option B: .env file** (same file as Supabase)

### Test Connection

Ask Kimi:

```
List the last 10 payments from Stripe
```

Or:

```
Show me Stripe customer details for customer cus_xxx
```

### Example Queries for CruiseApp

**Query 1: Analyze payment failures**
```
Find all failed payment intents from the last 7 days for our ride-sharing app. Show the failure reason, customer email, and amount.
```

**Query 2: Process a refund**
```
Create a refund for payment intent pi_xxx with reason "requested_by_customer". Confirm the refund status.
```

**Query 3: Revenue report**
```
Show me the total revenue, successful charges, and refund amount for the last 30 days.
```

---

## 3. Filesystem MCP Server

### What It Does
- Read/write files in your project
- Search across codebase
- Analyze file structure

### Already Configured
The filesystem MCP is already set up to access `c:\Users\Puma\cruiseapp.2`.

### Example Queries

```
Find all files that reference "driver_approval_status"
```

```
Show me the main.dart file
```

```
Search for all API endpoints defined in the backend
```

---

## 4. Firebase / Firestore — Alternative Approach

### Why No MCP?
There is **NO official Firebase MCP server** available. Google has not released one.

### Recommended Workarounds

#### Option A: Use Supabase MCP (Recommended)
Your backend already syncs data between Firestore and PostgreSQL. Use the Supabase MCP for database operations.

#### Option B: Firebase CLI + Python Scripts
Create helper scripts in your backend that Kimi can run:

```python
# backend/scripts/firestore_query.py
import firebase_admin
from firebase_admin import credentials, firestore

cred = credentials.Certificate("path/to/serviceAccountKey.json")
firebase_admin.initialize_app(cred)

db = firestore.client()

# Example: Get all drivers online
drivers = db.collection('drivers').where('isOnline', '==', True).stream()
for driver in drivers:
    print(driver.to_dict())
```

#### Option C: Firebase REST API
Use direct HTTP requests to Firestore REST API:
```
https://firestore.googleapis.com/v1/projects/YOUR_PROJECT_ID/databases/(default)/documents/drivers
```

---

## Security Best Practices

### ✅ DO
- Store secrets in environment variables
- Use `.env` files (add to `.gitignore`!)
- Use test keys for development
- Rotate keys regularly

### ❌ DON'T
- Hardcode passwords or API keys in `settings.json`
- Commit `.env` files to git
- Use production keys in development

### .gitignore Addition
Make sure your `.gitignore` includes:
```
.env
.env.local
.vscode/settings.local.json
*.pem
serviceAccountKey.json
```

---

## Troubleshooting

### MCP Server Not Starting
1. Check Node.js version: `node --version` (needs v18+)
2. Check npx works: `npx --version`
3. Restart VS Code after setting env variables

### Supabase Connection Failed
```
Error: password authentication failed
```
- Verify `SUPABASE_DB_PASSWORD` is set correctly
- Check if IP is allowlisted in Supabase Dashboard → Database → IPv4

### Stripe Connection Failed
```
Error: Invalid API Key
```
- Verify `STRIPE_SECRET_KEY` starts with `sk_test_` or `sk_live_`
- Make sure you're using the Secret Key, not Publishable Key

### Kimi Code Not Recognizing MCP
1. Open Command Palette: `Ctrl+Shift+P`
2. Run: `Kimi Code: Reload Window`
3. Check MCP status in Kimi Code panel

---

## Next Steps

1. ✅ Set `SUPABASE_DB_PASSWORD` environment variable
2. ✅ Set `STRIPE_SECRET_KEY` environment variable
3. ✅ Restart VS Code
4. ✅ Test with sample queries above
5. 🔲 Consider building custom Firebase MCP if needed
6. 🔲 Add more MCP servers as they become available

---

## Available MCP Servers (Community)

| Server | Install | Use Case |
|--------|---------|----------|
| `@stripe/mcp` | `npx -y @stripe/mcp` | Payments |
| `@gishubperu/mcp-postgresql` | `npx -y @gishubperu/mcp-postgresql` | PostgreSQL |
| `@antidrift/mcp-stripe` | `npx -y @antidrift/mcp-stripe` | Advanced Stripe |
| `@modelcontextprotocol/server-filesystem` | `npx -y @modelcontextprotocol/server-filesystem` | File access |

**Not Available:**
- Firebase/Firestore MCP ❌
- Supabase official MCP ❌ (use PostgreSQL MCP instead)
- Twilio MCP ❌
- OpenAI MCP ❌
- Mapbox MCP ❌
