# Coding Standards — CruiseApp

## Dart/Flutter Standards

### Naming Conventions
- Classes: `PascalCase` (e.g., `DriverProfileScreen`)
- Files: `snake_case` (e.g., `driver_profile_screen.dart`)
- Variables/functions: `camelCase` (e.g., `getUserProfile`)
- Constants: `camelCase` with `const` keyword
- Private members: prefix with `_`

### File Organization
- One widget per file (unless tightly coupled)
- Screens in `lib/screens/` organized by role (`driver/`, `rider/`)
- Services in `lib/services/`
- Models in `lib/models/`
- Localization in `lib/l10n/`

### Widget Best Practices
- Extract reusable widgets into separate files
- Use `const` constructors where possible
- Prefer `StatelessWidget` unless state is needed
- Keep `build()` methods concise

## Python/FastAPI Standards

### File Organization
- Endpoints grouped by domain (auth, trips, drivers, payments)
- Pydantic models separate from endpoint handlers
- Utility functions in dedicated modules
- Environment config via `.env` files

### Function Style
- Type hints on all parameters and return types
- Max function length: ~30 lines (extract if longer)
- Use `async def` for all endpoint handlers
- Use ASCII quotes only (no smart/curly quotes from copy-paste)

### API Conventions
- RESTful URL patterns: `/api/v1/{resource}`
- Consistent error response format: `{"detail": "message"}`
- HTTP status codes: 200, 201, 400, 401, 404, 500
- Pagination: `?limit=20&offset=0`

## Git Conventions

### Commit Messages
- Format: `type(scope): description`
- Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`
- Scopes: `rider`, `driver`, `backend`, `db`, `ui`, `auth`
- Example: `fix(auth): OTP email codes now work`
