# Common Antipatterns — CruiseApp

## Flutter Antipatterns

### 1. setState in async without mounted check
**Bad:**
```dart
Future<void> loadData() async {
  final data = await api.getData();
  setState(() => _data = data); // Widget may be disposed
}
```
**Good:**
```dart
Future<void> loadData() async {
  final data = await api.getData();
  if (mounted) setState(() => _data = data);
}
```

### 2. Not disposing controllers
**Bad:**
```dart
class MyScreen extends StatefulWidget {
  final controller = TextEditingController(); // Memory leak
}
```
**Good:**
```dart
late final TextEditingController _controller;
@override void initState() { _controller = TextEditingController(); }
@override void dispose() { _controller.dispose(); super.dispose(); }
```

### 3. Blocking the UI thread
**Bad:** Heavy computation in `build()` method
**Good:** Use `compute()` for heavy work, cache results

### 4. Hardcoded strings
**Bad:** `Text('Welcome back')`
**Good:** `Text(AppLocalizations.of(context)!.welcomeBack)`

## Python/FastAPI Antipatterns

### 1. Raw SQL without parameterization
**Bad:**
```python
query = f"SELECT * FROM users WHERE id = '{user_id}'"
```
**Good:**
```python
result = supabase.table("users").select("*").eq("id", user_id).execute()
```

### 2. Synchronous calls in async endpoints
**Bad:**
```python
@app.get("/users")
async def get_users():
    time.sleep(1)  # Blocks the event loop
```
**Good:**
```python
@app.get("/users")
async def get_users():
    await asyncio.sleep(1)  # Non-blocking
```

### 3. Missing error handling on Supabase calls
**Bad:**
```python
result = supabase.table("trips").select("*").execute()
return result.data
```
**Good:**
```python
try:
    result = supabase.table("trips").select("*").execute()
    return result.data
except Exception as e:
    logger.error(f"Failed to fetch trips: {e}")
    raise HTTPException(status_code=500, detail="Failed to fetch trips")
```

### 4. Smart quotes in Python code
**Bad:** Using curly/smart quotes from copy-paste
**Good:** Always use ASCII quotes `'` and `"`
**Note:** This caused real bugs in this project (commit 29b0712)

## Database Antipatterns

### 1. Missing columns in migrations
Always verify all required columns exist before deploying endpoints that reference them.
**Note:** This caused a 500 error on schedule ride (commit 3fa6055)

### 2. SELECT * in production
Only select the columns you need to reduce payload and improve performance.

### 3. No indexes on foreign keys
Always add indexes on columns used in WHERE clauses and JOINs.
