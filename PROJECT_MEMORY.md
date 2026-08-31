# 🚗 CruiseApp — Project Memory

> This file contains the complete architectural memory of the CruiseApp project.
> It is designed to be read by AI assistants to quickly understand the entire codebase.

---

## 1. PROJECT OVERVIEW

**CruiseApp** is a ride-sharing app (Uber/Lyft style) with two user roles:
- **Rider (Pasajero)**: Requests rides, tracks driver, pays, rates
- **Driver (Conductor)**: Goes online, receives trip offers, navigates to pickup/dropoff, earns money

**Tech Stack:**
- **Frontend**: Flutter 3.x (Dart) — iOS, Android, Web
- **Backend**: Python FastAPI 0.115.0 on Railway
- **Database**: PostgreSQL via Supabase + Firestore for real-time
- **Maps**: Mapbox Maps Flutter
- **Payments**: Stripe (cards, Apple Pay, Google Pay) + Tap to Pay
- **Auth**: Firebase Auth (email, Google, Apple)
- **Push Notifications**: Firebase Cloud Messaging (FCM)
- **AI Support**: OpenAI GPT-4o-mini with function calling
- **Real-time**: Socket.IO + Firestore listeners

**Build**: `1.0.2+435`

---

## 2. FLUTTER APP ARCHITECTURE (`lib/`)

### 2.1 Entry Point
- **`main.dart`**: App bootstrap, Firebase init, FCM setup, theme, localization
- **`firebase_options.dart`**: Firebase configuration per platform

### 2.2 Screens — Complete Directory

#### Rider Screens (Pasajero)
| Screen | File | Purpose |
|--------|------|---------|
| Splash | `splash_screen.dart` | App launch, auth check, role routing |
| Welcome | `welcome_screen.dart` | First-time user onboarding |
| Login | `login_screen.dart` | Phone/email login entry |
| Login Password | `login_password_screen.dart` | Password entry |
| Login Verify | `login_verify_screen.dart` | SMS code verification |
| Name | `name_screen.dart` | Collect user name during signup |
| Email Collect | `email_collect_screen.dart` | Collect email |
| Create Password | `create_password_screen.dart` | Set password |
| Forgot Password | `forgot_password_screen.dart` | Password reset flow |
| Verify Code | `verify_code_screen.dart` | Generic code verification |
| Welcome Back | `welcome_back_screen.dart` | Returning user welcome |
| **Home** | `home_screen.dart` | **MAIN RIDER SCREEN** — map, vehicle cards, where-to bar |
| Home Controller | `home_screen_controller.dart` | Home screen business logic |
| Home Map | `home_screen_map.dart` | Mapbox map for home screen |
| Home Widgets | `home_screen_widgets.dart` | Vehicle cards, quick access, fleet stack |
| Pickup/Dropoff Search | `pickup_dropoff_search_screen.dart` | Address search with autocomplete |
| Map Picker | `map_picker_screen.dart` | Choose location on map |
| **Ride Request** | `ride_request_screen.dart` | **MAIN BOOKING SCREEN** — map + vehicle selection + price |
| Ride Request Controller | `ride_request_controller.dart` | Booking logic, price calculation |
| Ride Request Map | `ride_request_map.dart` | Map for ride request |
| Ride Request Widgets | `ride_request_widgets.dart` | Vehicle cards grid, panels, overlays |
| Ride Options Sheet | `ride_options_sheet.dart` | Bottom sheet for ride options |
| Choose Ride Type | `choose_ride_type_screen.dart` | Select vehicle tier (VIP/Premium/Comfort) |
| Searching Driver | `searching_driver_screen.dart` | Searching for driver animation |
| Waiting for Driver | `waiting_for_driver_screen.dart` | Driver assigned, waiting for arrival |
| **Rider Tracking** | `rider_tracking_screen.dart` | **ACTIVE TRIP** — track driver on map |
| Rider Confirm Pickup | `rider_confirm_pickup_screen.dart` | Confirm driver arrived |
| Ride Rating | `ride_rating_screen.dart` | Rate driver after trip |
| Rider Rating | `rider_rating_screen.dart` | View rider's own rating |
| Trip Receipt | `trip_receipt_screen.dart` | Post-trip receipt |
| Ride History | `ride_history_screen.dart` | Past trips list |
| Scheduled Rides | `scheduled_rides_screen.dart` | View upcoming scheduled rides |
| Schedule Booking | `schedule_booking_screen.dart` | Schedule a ride for later |
| Schedule Picker Sheet | `schedule_picker_sheet.dart` | Date/time picker |
| Schedule Ride Flow | `schedule_ride_flow.dart` | Complete scheduled ride flow |
| Airport Terminal Sheet | `airport_terminal_sheet.dart` | Airport terminal selection |
| Ready to Ride | `ready_to_ride_screen.dart` | Pre-ride confirmation |
| Ride Booking Confirmed | `ride_booking_confirmed_screen.dart` | Booking confirmation screen |
| Ride Payment Method | `ride_payment_method_screen.dart` | Select payment for ride |
| Searching Border | `searching_border_painter.dart` | Animated border effect |

#### Driver Screens (Conductor)
| Screen | File | Purpose |
|--------|------|---------|
| Driver Login | `driver_login_screen.dart` | Driver auth |
| Driver Signup | `driver_signup_screen.dart` | Driver registration |
| Driver Approved | `driver_approved_screen.dart` | Approval confirmation |
| Driver Pending Review | `driver_pending_review_screen.dart` | Waiting for approval |
| Driver Documents | `driver_documents_screen.dart` | Upload license, insurance, etc. |
| License Scanner | `license_scanner_screen.dart` | Scan driver's license |
| Background Check Consent | `background_check_consent_screen.dart` | Checkr background check |
| Driver Profile Photo | `driver_profile_photo_screen.dart` | Upload profile photo |
| Driver Vehicle | `driver_vehicle_screen.dart` | Vehicle info |
| **Driver Home** | `driver_home_screen.dart` | **MAIN DRIVER SCREEN** — GO ONLINE button, map, earnings |
| **Driver Online** | `driver_online_screen.dart` | **ONLINE MODE** — searching for trips, offers, navigation |
| Driver Online Controller | `driver_online_controller.dart` | Online logic: polling, SSE, accept/reject |
| Driver Online Map | `driver_online_map.dart` | Map annotations, route drawing, camera |
| Driver Online Widgets | `driver_online_widgets.dart` | UI: searching bar, offer cards, panels |
| Driver Trip Accept | `driver_trip_accept_screen.dart` | Accept trip offer screen |
| Trip Accepted | `trip_accepted_screen.dart` | Trip in progress navigation |
| Driver Nav | `driver_nav_screen.dart` | Turn-by-turn navigation |
| Game Navigation | `game_navigation_screen.dart` | Gamified navigation view |
| Driver Rate Rider | `driver_rate_rider_screen.dart` | Rate rider after trip |
| Driver Earnings | `driver_earnings_screen.dart` | Earnings dashboard |
| Driver Analytics | `driver_analytics_screen.dart` | Performance analytics |
| Driver Trip History | `driver_trip_history_screen.dart` | Past trips |
| Driver Scheduled Trips | `driver_scheduled_trips_screen.dart` | Scheduled rides for driver |
| Scheduled Rides | `driver/scheduled_rides_screen.dart` | Scheduled rides marketplace |
| Scheduled Ride Details | `driver/scheduled_ride_details_screen.dart` | Details of scheduled ride |
| Scheduled Rides Marketplace | `driver/scheduled_rides_marketplace_screen.dart` | Claim scheduled rides |
| Driver Inbox | `driver_inbox_screen.dart` | Driver messages |
| Driver Promos | `driver_promos_screen.dart` | Driver promotions |
| Driver Referral | `driver_referral_screen.dart` | Driver referral program |
| Driver Menu | `driver_menu_screen.dart` | Driver side menu |
| Driver Settings | `driver_settings_screen.dart` | Driver settings |
| Driver Settings Pages | `driver_settings_pages.dart` | Sub-settings pages |
| Driver Manage Account | `driver_manage_account_screen.dart` | Account management |
| Driver Profile | `driver_profile_screen.dart` | Driver profile |
| Driver Safety | `driver_safety_screen.dart` | Safety features for driver |
| Driver Info Pages | `driver_info_pages.dart` | Info screens |
| Cruise Level | `driver/cruise_level_screen.dart` | Driver level/loyalty program |
| Payout Methods | `driver/payout_methods_screen.dart` | Payout setup |

#### Shared/Common Screens
| Screen | File | Purpose |
|--------|------|---------|
| Chat | `chat_screen.dart` | Rider-Driver chat |
| Safety | `safety_screen.dart` | Safety toolkit |
| Help | `help_screen.dart` | Help & support |
| **AI Support** | `services/ai_support_service.dart` | OpenAI GPT-4o support chat |
| Notifications | `notifications_screen.dart` | Notification history |
| Notification Settings | `notification_settings_screen.dart` | FCM topic preferences |
| Account | `account_screen.dart` | Account management |
| Edit Profile | `edit_profile_screen.dart` | Edit profile info |
| Profile Photo | `profile_photo_screen.dart` | Upload profile photo |
| Profile Review | `profile_review_screen.dart` | Profile under review |
| Identity Verification | `identity_verification_screen.dart` | ID verification |
| Face Liveness | `face_liveness_screen.dart` | Selfie liveness check |
| Wallet | `wallet_screen.dart` | Cruise Cash wallet |
| Transfer Cruise Cash | `transfer_cruise_cruise_screen.dart` | Transfer balance |
| Promo Code | `promo_code_screen.dart` | Apply promo code |
| Referral | `referral_screen.dart` | Referral program |
| Payment Method | `payment_method_screen.dart` | Manage payment methods |
| Credit Card | `credit_card_screen.dart` | Add credit card |
| Payment Accounts | `payment_accounts_screen.dart` | Payment accounts |
| PayPal Checkout | `paypal_checkout_screen.dart` | PayPal payment |
| Tap to Pay | `tap_to_pay_screen.dart` | In-person card payment |
| Saved Addresses | `saved_addresses_screen.dart` | Favorite places |
| Terms of Service | `terms_of_service_screen.dart` | Legal |
| Privacy Policy | `privacy_policy_screen.dart` | Privacy |
| About | `about_screen.dart` | About app |
| Accessibility | `accessibility_screen.dart` | Accessibility settings |
| Account Deactivated | `account_deactivated_screen.dart` | Deactivated account |
| Inbox | `inbox_screen.dart` | Messages inbox |

### 2.3 Services (`lib/services/`)
| Service | File | Purpose |
|---------|------|---------|
| API Service | `api_service.dart` | HTTP client, all backend calls |
| Auth (Google) | `google_auth_service.dart` | Google Sign-In |
| Auth (Apple) | `apple_auth_service.dart` | Apple Sign-In |
| Places | `places_service.dart` | Mapbox/Google address autocomplete |
| Directions | `directions_service.dart` | Route calculation |
| GPS | `gps_service.dart` | Location tracking |
| Payment | `payment_service.dart` | Stripe payments |
| Tap to Pay | `tap_to_pay_service.dart` | In-person payments |
| Notification | `notification_service.dart` | Local notifications + sounds |
| FCM | `fcm_service.dart` | Push notification handling |
| Chat | `chat_service.dart` | Chat messaging |
| Trip Firestore | `trip_firestore_service.dart` | Real-time trip data |
| Socket | `socket_service.dart` | Socket.IO connection |
| Network | `network_service.dart` | Connectivity monitoring |
| Analytics | `analytics_service.dart` | Event tracking |
| Local Data | `local_data_service.dart` | SharedPreferences wrapper |
| Local Cache | `local_cache.dart` | Key-value cache |
| Map Cache | `map_cache_service.dart` | Map tile pre-caching |
| Cache | `cache_service.dart` | General caching |
| Preload | `preload_service.dart` | Asset preloading |
| Security | `security_service.dart` | Security checks |
| User Session | `user_session.dart` | Session management |
| Prefs Cache | `prefs_cache.dart` | Preference caching |
| Navigation | `navigation_service.dart` | App navigation helpers |
| Map Launcher | `map_launcher_service.dart` | Open external maps |
| Offline | `offline_service.dart` | Offline mode handling |
| Keep Alive | `keep_alive_service.dart` | Background keep-alive |
| Email | `email_service.dart` | Email sending |
| SMS | `sms_service.dart` | SMS sending |
| Complimentary Drink | `complimentary_drink_service.dart` | VIP drink menu |
| Driver Report | `driver_report_service.dart` | Driver incident reports |
| Error | `error_service.dart` | Error handling |
| Photo Recovery | `photo_recovery_service.dart` | Photo backup recovery |
| Firebase Storage | `firebase_storage_service.dart` | Cloud storage |
| AI Support | `ai_support_service.dart` | OpenAI integration |

### 2.4 Key Widgets (`lib/widgets/`)
| Widget | File | Purpose |
|--------|------|---------|
| Gold Particles Background | `gold_particles_background.dart` | Animated sparkle particles |
| Car Image 3D | `car_image_3d.dart` | 3D car with shadows + gold glow |
| Vehicle Tier Badge | `vehicle_tier_badge.dart` | VIP/Premium/Comfort badge with halo |
| Gold Location Dot | `gold_location_dot.dart` | Animated gold location dot |
| Gold Pin Renderer | `gold_pin_renderer.dart` | Custom map pin renderer |
| Circular Pin Renderer | `map/circular_pin_renderer.dart` | Circular map pins |
| Verified Avatar | `verified_avatar.dart` | Profile photo with verification badge |
| User Profile Photo | `user_profile_photo.dart` | User photo widget |
| Profile Avatar | `common/profile_avatar.dart` | Reusable avatar |
| Typing Indicator | `typing_indicator.dart` | Chat typing animation |
| Offline Banner | `offline_banner.dart` | Network offline indicator |
| Offer Banner | `offer_banner.dart` | Trip offer banner |
| Driver Action Panel | `driver_action_panel.dart` | Driver bottom action panel |
| Driver Navigation Panel | `driver_navigation_panel.dart` | Navigation instructions panel |
| Driver Info Card | `tracking/driver_info_card.dart` | Driver info in tracking |
| ETA Display | `tracking/eta_display.dart` | ETA countdown |
| Tracking Map View | `tracking/tracking_map_view.dart` | Map for trip tracking |
| Trip Action Buttons | `tracking/trip_action_buttons.dart` | Call/message/cancel buttons |
| Trip Phase Indicator | `tracking/trip_phase_indicator.dart` | Trip progress steps |
| Fare Breakdown | `fare_breakdown_widget.dart` | Price breakdown |
| Velocity Aware Panel | `velocity_aware_panel.dart` | Panel that hides on movement |
| Smart Map Pin | `smart_map_pin.dart` | Intelligent map pin |
| Cruise Map Pin | `cruise_map_pin.dart` | Branded map pin |
| Animated Map Label | `map/animated_map_label.dart` | Animated map labels |
| Shimmer Placeholders | `shimmer_placeholders.dart` | Loading shimmer effects |
| Bouncing Button | `bouncing_button.dart` | Button with bounce animation |
| Place Search Field | `place_search_field.dart` | Reusable address search field |

### 2.5 Configuration (`lib/config/`)
| File | Purpose |
|------|---------|
| `api_keys.dart` | API keys (Mapbox, Google Places, etc.) |
| `app_config.dart` | App-wide configuration |
| `app_theme.dart` | Theme data, colors |
| `mapbox_config.dart` | Mapbox token, style URLs |
| `map_styles.dart` | Map style JSON |
| `map_theme.dart` | Map theming |
| `page_transitions.dart` | Custom route transitions |
| `smooth_transitions.dart` | Smooth animation curves |
| `env.dart` | Environment variables (gitignored) |
| `env.template.dart` | Template for env.dart |
| `feature_flags.dart` | Feature toggles |
| `theme_notifier.dart` | Dark/light mode notifier |
| `responsive_utils.dart` | Responsive design helpers |

### 2.6 Models (`lib/models/`)
| Model | File |
|-------|------|
| LatLng | `lat_lng.dart` |
| Chat Message | `chat_message.dart` |
| Ride Offer | `ride_offer.dart` |
| Airport Models | `airport_models.dart` |

### 2.7 Navigation & Rendering (`lib/navigation/`)
| File | Purpose |
|------|---------|
| `car_icon_loader.dart` | Load car icon bytes |
| `car_renderers.dart` | Render car on map |
| `suv_renderer.dart` | SUV-specific renderer |
| `game_car_renderer.dart` | Gamified car renderer |
| `glowing_route_renderer.dart` | Glowing route effect |
| `nav_state_machine.dart` | Navigation state machine |
| `route_service.dart` | Route calculation service |
| `route_snapper.dart` | Snap to roads |
| `smooth_motion.dart` | Smooth GPS interpolation |
| `offers_controller.dart` | Offer management |
| `navatar_loader.dart` | Navatar (nav avatar) loading |
| `navatar_picker.dart` | Navatar selection |
| `navatar_sprite_generator.dart` | Navatar sprite generation |

### 2.8 State Management
- **`rider_trip_controller.dart`**: Rider trip state (active trip, phase, etc.)
- **`accessibility_notifier.dart`**: Accessibility settings
- **Provider/ValueNotifier pattern** throughout the app

---

## 3. BACKEND ARCHITECTURE (`backend/`)

### 3.1 Main Entry
- **`main.py`**: FastAPI app, middleware, router registration
- **`config.py`**: Configuration, DB connection
- **`startup.py`**: Startup tasks

### 3.2 Routers (API Endpoints)
| Router | File | Endpoints |
|--------|------|-----------|
| Auth | `routers/auth.py` | Login, register, verify, password reset |
| Drivers | `routers/drivers.py` | Driver profile, docs, status |
| Trips | `routers/trips.py` | Create, update, complete trips |
| Dispatch | `routers/dispatch.py` | Trip matching, offers, SSE |
| Payments | `routers/payments.py` | Stripe, charges, payouts |
| Scheduled | `routers/scheduled.py` | Scheduled rides |
| VIP | `routers/vip.py` | VIP features, drinks |
| Support | `routers/support.py` | AI support chat, OpenAI |
| Referrals | `routers/referrals.py` | Referral program |
| Driver Referrals | `routers/driver_referrals.py` | Driver referrals |
| Voice | `routers/voice.py` | Voice features |
| Admin | `routers/admin.py` | Admin dashboard |
| Misc | `routers/misc.py` | Health check, etc. |

### 3.3 Services
| Service | File | Purpose |
|---------|------|---------|
| OpenAI Support | `services/openai_support_service.py` | GPT-4o integration |
| FCM | `services/fcm_service.py` | Push notification sending |
| Email | `services/email_service.py` | SendGrid email |
| SMS | `services/sms_service.py` | Twilio SMS |
| Email SMS | `services/email_sms_service.py` | Combined service |
| SocketIO | `services/socketio_service.py` | Real-time events |
| Event Bus | `services/event_bus.py` | Internal event bus |
| Checkr | `services/checkr_service.py` | Background checks |
| Admin Alerts | `services/admin_alerts_service.py` | Admin notifications |
| Guest Link | `services/guest_link_service.py` | Guest referral links |
| N8N Webhooks | `services/n8n_webhooks.py` | n8n automation |

### 3.4 Models
- **`models/database.py`**: SQLAlchemy models (User, Driver, Trip, etc.)
- **`models/schemas.py`**: Pydantic schemas

### 3.5 Background Agents (Async Tasks)
| Agent | File | Purpose |
|-------|------|---------|
| Ghost Driver | `ghost_driver_agent.py` | Detect inactive drivers |
| Guardian | `guardian_agent.py` | Monitor system health |
| Document Approval | `document_approval_agent.py` | Auto-approve documents |
| Document Expiry | `document_expiry_agent.py` | Alert expiring docs |
| Proactive Support | `proactive_support_agent.py` | Predictive support |
| Rating Moderator | `rating_moderator_agent.py` | Review ratings |
| Safety Monitor | `safety_monitor_agent.py` | Safety alerts |
| Security Guardian | `security_guardian.py` | Security monitoring |
| Server Guardian | `server_guardian.py` | Server health |
| Wait Timeout | `wait_timeout_agent.py` | Handle driver no-shows |
| Cruise Level | `cruise_level_agent.py` | Driver loyalty program |
| Firestore Sync | `firestore_sync.py` | Sync PostgreSQL ↔ Firestore |

### 3.6 Webhooks
- **`webhooks/stripe_webhook.py`**: Stripe payment webhooks

---

## 4. USER FLOWS

### 4.1 Rider Flow
```
[Splash] → [Welcome/Login] → [Home]
                                    ↓
                              [Pickup/Dropoff Search]
                                    ↓
                              [Ride Request Screen]
                                    ↓
                              [Searching Driver] → [Waiting for Driver]
                                    ↓
                              [Rider Tracking] (trip in progress)
                                    ↓
                              [Ride Rating] → [Trip Receipt]
```

### 4.2 Driver Flow
```
[Splash] → [Driver Login/Signup] → [Driver Home]
                                          ↓
                                    [GO ONLINE]
                                          ↓
                                    [Driver Online] (searching)
                                          ↓
                                    [Trip Offer] → Accept/Decline
                                          ↓
                                    [Trip Accepted] (navigate to pickup)
                                          ↓
                                    [En Route] → [Arrived] → [In Trip]
                                          ↓
                                    [Complete] → [Rate Rider]
```

### 4.3 VIP/Drinks Flow
- VIP riders see complimentary drink menu
- Driver sees rider's drink order
- Backend emails drink order to venue

### 4.4 Airport Flow
- Rider selects airport as destination
- Terminal selection sheet appears
- Special airport pricing

### 4.5 Scheduled Rides Flow
- Rider schedules ride for future date/time
- Driver can claim scheduled rides in advance
- FCM reminder 15 min before pickup

---

## 5. KEY INTEGRATIONS

### 5.1 Mapbox
- **File**: `lib/config/mapbox_config.dart`
- **Token**: `ApiKeys.mapbox` (from `api_keys.dart`)
- **Style**: Dark theme (`mapbox://styles/...`)
- **Features**: Maps, geocoding, directions, search

### 5.2 Stripe
- **File**: `lib/services/payment_service.dart`
- **Features**: Cards, Apple Pay, Google Pay, Tap to Pay
- **Webhook**: `backend/webhooks/stripe_webhook.py`

### 5.3 Firebase
- **Auth**: Email, Google, Apple sign-in
- **FCM**: Push notifications (`lib/main.dart`)
- **Firestore**: Real-time trip data, chat
- **Crashlytics**: Error reporting
- **Analytics**: Event tracking

### 5.4 Supabase/PostgreSQL
- **Main DB**: Users, drivers, trips, payments
- **File**: `backend/config.py`

### 5.5 OpenAI
- **File**: `backend/services/openai_support_service.py`
- **Model**: GPT-4o-mini (configurable to GPT-4o)
- **Features**: AI support chat with function calling
- **Functions**: cancel_trip, apply_promo_credit, process_refund, flag_driver, escalate_to_human, get_trip_details, get_user_trips

### 5.6 Socket.IO
- **File**: `backend/services/socketio_service.py`
- **Purpose**: Real-time driver location, trip updates

### 5.7 n8n
- **Directory**: `n8n/workflows/`
- **Workflows**: Driver assignment, trip notifications

---

## 6. IMPORTANT FILES & THEIR ROLES

### 6.1 Most Critical Files
| File | Why It's Critical |
|------|-------------------|
| `lib/main.dart` | App entry, Firebase init, FCM handler, theme |
| `lib/services/api_service.dart` | ALL backend HTTP calls |
| `lib/services/notification_service.dart` | Local notifications, sounds |
| `lib/screens/home_screen.dart` | Main rider screen |
| `lib/screens/driver/driver_home_screen.dart` | Main driver screen |
| `lib/screens/driver/driver_online_screen.dart` | Driver online mode |
| `lib/screens/ride_request_screen.dart` | Ride booking |
| `lib/screens/rider_tracking_screen.dart` | Active trip tracking |
| `backend/main.py` | FastAPI app |
| `backend/routers/dispatch.py` | Trip matching logic |
| `backend/services/openai_support_service.py` | AI support |

### 6.2 Configuration Files
| File | Purpose |
|------|---------|
| `lib/config/api_keys.dart` | API keys (NEVER commit real keys) |
| `lib/config/env.dart` | Environment variables (gitignored) |
| `backend/.env` | Backend env vars (gitignored) |
| `pubspec.yaml` | Flutter dependencies |
| `backend/requirements.txt` | Python dependencies |

---

## 7. BUILD & DEPLOYMENT

### 7.1 Flutter Build
```bash
flutter build ios --release
flutter build apk --release
flutter build appbundle --release
```

### 7.2 Backend Deploy
- **Platform**: Railway
- **Command**: `railway up` or auto-deploy on push

### 7.3 CI/CD
- **File**: `.github/workflows/`
- **Checks**: `flutter analyze`, backend `pytest`

---

## 8. SECURITY NOTES

- `env.dart` and `.env` are gitignored
- API keys should NEVER be committed
- OpenAI API key was previously exposed — must be rotated
- Stripe webhooks validate signatures
- Firebase Auth tokens verified on backend

---

## 9. RECENT CHANGES (Context Window)

### Latest Commit
- Fix: defer haptic+sound 300ms, fire-and-forget audio play
- Files: `driver_home_screen.dart`, `notification_service.dart`

### Previous Commit
- Fix: address search, vehicle cards, notifications, GO ONLINE freeze
- Files: 9 files including `pickup_dropoff_search_screen.dart`, `ride_request_widgets.dart`, `main.dart`

---

## 10. HOW TO USE THIS MEMORY

When working on CruiseApp:
1. **Read this file first** to understand the architecture
2. **Check the screen/service list** to find where a feature lives
3. **Follow the user flows** to understand the navigation path
4. **Check integrations** to understand external dependencies

This memory is updated after significant architectural changes.
