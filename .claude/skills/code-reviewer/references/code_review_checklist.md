# Code Review Checklist — CruiseApp

## Flutter/Dart Checks

### Null Safety
- All variables properly typed (no unnecessary `dynamic`)
- Null checks before accessing nullable properties
- Use of `??` and `?.` operators where appropriate
- Late variables justified and documented

### Widget Lifecycle
- `dispose()` called for controllers, streams, timers
- No memory leaks from uncancelled subscriptions
- `mounted` check before `setState()` in async callbacks
- Proper use of `const` constructors

### State Management
- No unnecessary rebuilds
- State not stored in widgets that rebuild frequently
- Proper separation of UI and business logic

### Async Patterns
- All futures properly awaited or handled
- Error handling with try/catch on network calls
- Loading states shown during async operations
- Cancellation of pending requests on dispose

### Localization
- No hardcoded user-facing strings
- All strings in `lib/l10n/app_localizations.dart`
- RTL support considered

## Python/FastAPI Checks

### Endpoint Security
- Authentication required on protected endpoints
- Input validation with Pydantic models
- No raw SQL — use parameterized queries via Supabase client
- Rate limiting on auth endpoints (OTP, login)

### Error Handling
- HTTPException with proper status codes
- No leaking of internal errors to client
- Logging of errors with context (user_id, endpoint)
- Graceful handling of Supabase connection failures

### Performance
- No N+1 queries (check loops with DB calls)
- Proper use of async/await (no blocking calls)
- Response pagination for list endpoints
- Indexes on frequently queried columns

### Type Safety
- Type hints on all function signatures
- Pydantic models for request/response bodies
- No bare `except:` clauses
- No mutable default arguments

## Supabase/Database Checks

### Migrations
- All schema changes in migration files
- Backwards-compatible column additions
- No data loss in migrations
- RLS (Row Level Security) policies reviewed

### Queries
- Proper use of Supabase client methods
- Select only needed columns (no `select(*)` in production)
- Foreign key relationships validated
- Proper indexing on join columns
