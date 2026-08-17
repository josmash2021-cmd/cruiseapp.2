import 'package:flutter/material.dart';

/// App-wide localization helper. Usage: `S.of(context).key`
/// Auto-detects device language (English / Spanish).
class S {
  final Locale locale;
  S(this.locale);

  static S of(BuildContext context) {
    return Localizations.of<S>(context, S) ?? S(const Locale('en'));
  }

  static const LocalizationsDelegate<S> delegate = _SDelegate();

  bool get _es => locale.languageCode == 'es';

  /// Public locale check for the few places that pick UNITS (meters vs
  /// feet) rather than words.
  bool get isSpanish => _es;

  // ── General / Shared ──────────────────────────────────────────────────────
  String get appName => 'Cruise';
  String get continueButton => _es ? 'Continuar' : 'Continue';
  String get next => _es ? 'Siguiente' : 'Next';
  String get skip => _es ? 'Omitir' : 'Skip';
  String get cancel => _es ? 'Cancelar' : 'Cancel';
  String get delete => _es ? 'Eliminar' : 'Delete';
  String get save => _es ? 'Guardar' : 'Save';
  String get confirm => _es ? 'Confirmar' : 'Confirm';
  String get apply => _es ? 'Aplicar' : 'Apply';
  String get send => _es ? 'Enviar' : 'Send';
  String get loading => _es ? 'Cargando...' : 'Loading...';
  String get gotIt => _es ? 'Entendido' : 'Got it';
  String get done => _es ? 'Listo' : 'Done';
  String get back => _es ? 'Atrás' : 'Back';
  String get error => _es ? 'Error' : 'Error';
  String get success => _es ? 'Éxito' : 'Success';
  String get yes => _es ? 'Sí' : 'Yes';
  String get no => _es ? 'No' : 'No';
  String get ok => 'OK';
  String get noCameraAvailable => _es
      ? 'No hay cámara disponible en este dispositivo'
      : 'No camera available on this device';
  String get retry => _es ? 'Reintentar' : 'Retry';
  String get close => _es ? 'Cerrar' : 'Close';

  // ── Welcome / Splash ──────────────────────────────────────────────────────
  String get welcomeHeadline =>
      _es ? 'Déjanos\nllevarte' : "Let's get\nyou there";
  String get welcomeSubheadline => _es
      ? 'Viajes premium al alcance de tu mano.'
      : 'Premium rides at your fingertips.';
  String get getStarted => _es ? 'Comenzar' : 'Get started';

  // ── Login ─────────────────────────────────────────────────────────────────
  String get welcomeBack => _es ? 'Bienvenido de vuelta' : 'Welcome back';
  String get signInSubtitle => _es
      ? 'Inicia sesión con tu correo o número de teléfono.'
      : 'Sign in with your email or phone number.';
  String get emailOrPhone =>
      _es ? 'Correo electrónico o teléfono' : 'Email or phone';
  String get invalidEmail => _es
      ? 'Por favor introduce una dirección de correo válida'
      : 'Please enter a valid email address';
  String get invalidPhone => _es
      ? 'Introduce un número de teléfono válido de 10 dígitos'
      : 'Enter a valid 10-digit US phone number';
  String get accountExists => _es ? 'La cuenta ya existe' : 'Account Exists';
  String get signInTitle =>
      _es ? 'Inicia sesión en Cruise' : 'Sign in to Cruise';
  String get password => _es ? 'Contraseña' : 'Password';
  String get forgotPassword =>
      _es ? '¿Olvidaste tu contraseña?' : 'Forgot password?';
  String get signIn => _es ? 'Iniciar sesión' : 'Sign in';
  String get biometricFailed => _es
      ? 'La autenticación biométrica falló'
      : 'Biometric authentication failed';
  String get sessionExpired => _es
      ? 'Tu sesión expiró. Por favor inicia sesión con tu contraseña.'
      : 'Session expired. Please sign in with your password.';
  String get verifyYourCode => _es ? 'Verifica tu código' : 'Verify your code';
  String get sixDigitCode => _es ? 'Código de 6 dígitos' : '6-digit code';
  String get verify => _es ? 'Verificar' : 'Verify';
  String get invalidCode => _es ? 'Código inválido' : 'Invalid code';
  String get driverAccountError => _es
      ? 'Esta cuenta está registrada como conductor. Por favor usa la opción de conductor.'
      : 'This account is registered as a driver. Please use Driver login.';
  String get riderAccountError => _es
      ? 'Esta cuenta está registrada como pasajero. Por favor usa la opción de pasajero.'
      : 'This account is registered as a rider. Please use Rider login.';

  // ── Create Password ───────────────────────────────────────────────────────
  String get createPassword =>
      _es ? 'Crea una contraseña' : 'Create a password';
  String get passwordRequirements => _es
      ? 'Debe incluir 8+ caracteres, 1 número, 1 mayúscula y 1 carácter especial.'
      : 'Must include 8+ chars, 1 number, 1 uppercase & 1 special character.';
  String get confirmPassword =>
      _es ? 'Confirma tu contraseña' : 'Confirm password';
  String get atLeast8Chars =>
      _es ? 'Al menos 8 caracteres' : 'At least 8 characters';
  String get containsNumber => _es ? 'Contiene un número' : 'Contains a number';
  String get anUppercase => _es ? 'Una letra mayúscula' : 'An uppercase letter';
  String get aSpecialChar => _es
      ? 'Un carácter especial (!@#\$ etc.)'
      : "A special character (!@#\$'s etc.)";
  String get passwordsMatch =>
      _es ? 'Las contraseñas coinciden' : 'Passwords match';
  String get passwordTooShort => _es
      ? 'La contraseña debe tener al menos 8 caracteres'
      : 'Password must be at least 8 characters';
  String get passwordNeedsNumber => _es
      ? 'La contraseña debe contener al menos 1 número'
      : 'Password must contain at least 1 number';
  String get passwordNeedsUppercase => _es
      ? 'La contraseña debe contener al menos 1 letra mayúscula'
      : 'Password must contain at least 1 uppercase letter';
  String get passwordNeedsSpecial => _es
      ? 'La contraseña debe contener al menos 1 carácter especial'
      : 'Password must contain at least 1 special character';
  String get passwordsMismatch =>
      _es ? 'Las contraseñas no coinciden' : 'Passwords do not match';
  String get passwordNotFound => _es
      ? 'Contraseña no encontrada. Por favor regresa y crea una contraseña.'
      : 'Password not found. Please go back and create a password.';

  // ── Name Screen ───────────────────────────────────────────────────────────
  String get whatsYourName => _es ? '¿Cuál es tu nombre?' : "What's your name?";
  String get driversWillSeeFirstName => _es
      ? 'Los conductores solo verán tu primer nombre'
      : 'Drivers will only see your first name';
  String get firstName => _es ? 'Nombre' : 'First Name';
  String get lastName => _es ? 'Apellido' : 'Last Name';
  String get alreadyHaveAccount =>
      _es ? '¿Ya tienes una cuenta?' : 'Already have an account?';
  String get verifyingTerms =>
      _es ? 'Verificando términos…' : 'Verifying terms…';

  // ── Email Collect Screen ──────────────────────────────────────────────────
  String greetSharePhone(String name) => _es
      ? 'Encantado de conocerte, $name.\n¿Nos compartirías tu número de teléfono?'
      : 'Great to meet you, $name.\nMind sharing your phone number?';
  String greetShareEmail(String name) => _es
      ? 'Encantado de conocerte, $name.\n¿Nos compartirías tu correo electrónico?'
      : 'Great to meet you, $name.\nMind sharing your email?';
  String get needPhoneSubtitle => _es
      ? 'Necesitamos un número para contactarte sobre tus viajes.'
      : 'We need a number to reach you about your rides.';
  String get needEmailSubtitle => _es
      ? 'Los recibos de viajes y actualizaciones de cuenta necesitan un destino.'
      : 'Ride receipts and account updates need to get sent somewhere.';
  String get phoneNumber => _es ? 'Número de teléfono' : 'Phone number';
  String get email => _es ? 'Correo electrónico' : 'Email';
  String get invalidPhoneError => _es
      ? 'Por favor introduce un número de teléfono válido'
      : 'Please enter a valid phone number';
  String get invalidEmailError => _es
      ? 'Por favor introduce una dirección de correo válida'
      : 'Please enter a valid email address';

  // ── Profile Photo ─────────────────────────────────────────────────────────
  String get readyCloseUp =>
      _es ? 'Prepárate para tu\nprimer plano' : 'Get ready for your\nclose-up';
  String get addPhotoSubtitle => _es
      ? 'Añade una foto para que los conductores te reconozcan'
      : 'Add a photo so drivers recognize you';
  String get takePhoto => _es ? 'Tomar Foto' : 'Take Photo';
  String get useYourCamera => _es ? 'Usa tu cámara' : 'Use your camera';
  String get selectFromPhotos =>
      _es ? 'Selecciona de tus fotos' : 'Select from photos';
  String get chooseFromGallery =>
      _es ? 'Seleccionar de la Galería' : 'Choose from Gallery';

  // ── Profile Review ────────────────────────────────────────────────────────
  String get everythingLookGood =>
      _es ? '¿Todo se ve bien\nhasta ahora?' : 'Everything look good\nso far?';
  String get reviewInfoSubtitle => _es
      ? "Asegúrate de que tu información sea correcta — aún estás\na tiempo de añadir una foto."
      : "Make sure your info is correct - it's not too late\nto add a photo.";
  String get selectGenderHint =>
      _es ? 'Selecciona tu género*' : 'Select your gender*';
  String get genderPrivacyNote => _es
      ? 'Usamos esta información de acuerdo con nuestra Política de Privacidad, incluyendo para personalizar tu experiencia con Cruise.'
      : 'We use this information in accordance with our Privacy Policy, including to personalize your experience with Cruise.';
  String get saveProfile => _es ? 'Guardar perfil' : 'Save profile';
  String get passwordMinSix => _es
      ? 'La contraseña debe tener al menos 6 caracteres'
      : 'Password must be at least 6 characters';
  String get accountExistsDiffCreds => _es
      ? 'La cuenta ya existe con diferentes credenciales. Intenta iniciar sesión.'
      : 'Account already exists with different credentials. Try logging in.';
  String get registrationFailed =>
      _es ? 'Error en el registro' : 'Registration failed';

  // ── Ready to Ride ─────────────────────────────────────────────────────────
  String get readyToRide => _es
      ? 'Estás listo para viajar.\nEstaremos aquí cuando nos necesites.'
      : "You're set to ride. We're\nhere when you need us.";
  String get almostReady => _es ? 'Casi listo...' : 'Almost ready...';
  String get safetyPoint1 => _es
      ? 'Todos los conductores deben pasar verificaciones de antecedentes regulares.'
      : 'All drivers must pass regular background checks.';
  String get safetyPoint2 => _es
      ? 'Monitoreamos los viajes para detectar actividades inusuales y verificamos si notamos algo incorrecto.'
      : 'We monitor rides for unusual activity, like route deviations, and check in if we notice something wrong.';
  String get safetyPoint3 => _es
      ? 'Si te sientes inseguro, puedes conectarte discretamente con un profesional de seguridad desde tu aplicación.'
      : 'If you feel unsafe, you can discreetly connect with a security professional from your app.';
  String get takeFirstRide =>
      _es ? 'Realiza tu primer viaje' : 'Take your first ride';
  String get enableLocationTitle =>
      _es ? 'Activa tu ubicación' : 'Enable your location';
  String get enableLocationDesc => _es
      ? 'Cruise necesita acceso a tu ubicación en tiempo real para conectarte con conductores cercanos y rastrear tus viajes.'
      : 'Cruise needs access to your real-time location to connect you with nearby drivers and track your rides.';
  String get allowLocation => _es ? 'Permitir ubicación' : 'Allow location';
  String get locationAlwaysOn => _es
      ? 'Mantén la ubicación siempre activa para una mejor experiencia.'
      : 'Keep location always on for the best experience.';
  String get add => _es ? 'Agregar' : 'Add';
  String get paymentInfoSecure => _es
      ? 'Tu información de pago está encriptada y almacenada de forma segura.\nCruise nunca verá los detalles de tu tarjeta.'
      : 'Your payment information is securely encrypted and stored.\nCruise never sees your card details.';

  // ── Account Verification ──────────────────────────────────────────────────
  String get verifyAccountTitle =>
      _es ? 'Verifica tu cuenta' : 'Verify your account';
  String get verifyAccountDesc => _es
      ? 'Verifica tu cuenta para empezar a solicitar rides. Esto nos ayuda a mantener segura a nuestra comunidad.'
      : 'Verify your account to start requesting rides. This helps us keep our community safe.';
  String get verifyNow => _es ? 'Verificar ahora' : 'Verify now';
  String get accountPendingTitle =>
      _es ? 'Verificación pendiente' : 'Verification pending';
  String get accountPendingDesc => _es
      ? 'Tu cuenta está siendo revisada. Te notificaremos cuando esté aprobada.'
      : 'Your account is being reviewed. We\'ll notify you when it\'s approved.';
  String get accountApproved => _es ? '¡Cuenta aprobada!' : 'Account approved!';
  String get accountApprovedDesc => _es
      ? '¡Tu cuenta ha sido verificada! Ya puedes solicitar rides.'
      : 'Your account has been verified! You can now request rides.';

  // ── Home Screen ───────────────────────────────────────────────────────────
  String get whereToQuestion => _es ? '¿A dónde?' : 'Where to?';
  String get pickup => _es ? 'Recogida' : 'Pickup';
  String get dropoff => _es ? 'Destino' : 'Dropoff';
  String get currentLocation => _es ? 'Ubicación actual' : 'Current location';
  String get liveLocation => _es ? 'Ubicación en vivo' : 'Live Location';
  String get welcomeGift => _es ? '¡Regalo de Bienvenida!' : 'Welcome Gift!';
  String get welcomePromoDesc => _es
      ? 'Como bienvenida a Cruise, ¡disfruta un 10% de descuento en tu primer viaje!'
      : 'As a welcome to Cruise, enjoy 10% off your first ride!';
  String get applyAndRide => _es ? 'Aplicar y Viajar' : 'Apply & Ride';
  String get promoLocked => _es ? 'Promo Bloqueada' : 'Promo Locked';
  String promoUnlockMsg(int n) => _es
      ? 'Completa $n viaje(s) más para desbloquear una recompensa.'
      : 'Complete $n more ride(s) to unlock a reward.';
  String get locationDisabled => _es
      ? 'Servicios de ubicación deshabilitados'
      : 'Location services disabled';
  String get locationDenied =>
      _es ? 'Permiso de ubicación denegado' : 'Location permission denied';
  String get locationDeniedForever => _es
      ? 'Permiso de ubicación denegado permanentemente'
      : 'Location permission permanently denied';
  String get unableToGetLocation =>
      _es ? 'No se pudo obtener la ubicación' : 'Unable to get location';
  String get chooseYourRide => _es ? 'Elige tu viaje' : 'Choose your ride';
  String get airport => _es ? 'Aeropuerto' : 'Airport';
  String get insured => _es ? 'Asegurado' : 'Insured';
  String get cash => _es ? 'Efectivo' : 'Cash';
  String get searchingForDriver =>
      _es ? 'Buscando conductor...' : 'Searching for driver...';
  String get rideRequested => _es ? 'Viaje solicitado' : 'Ride requested';
  String get cancelRide => _es ? 'Cancelar viaje' : 'Cancel ride';
  String get noDriversAvailable => _es
      ? 'No hay conductores disponibles en este momento'
      : 'No drivers available right now';
  String get scheduleRide => _es ? 'Programar viaje' : 'Schedule ride';

  // ── Account ───────────────────────────────────────────────────────────────
  String get yourAccount => _es ? 'Tu Cuenta' : 'Your Account';
  String get savedAddresses =>
      _es ? 'Direcciones Guardadas' : 'Saved Addresses';
  String get home => _es ? 'Inicio' : 'Home';
  String get work => _es ? 'Trabajo' : 'Work';
  String get editProfile => _es ? 'Editar Perfil' : 'Edit Profile';
  String get paymentMethods => _es ? 'Métodos de Pago' : 'Payment Methods';
  String get wallet => _es ? 'Billetera' : 'Wallet';
  String get rideHistory => _es ? 'Historial de Viajes' : 'Ride History';
  String get notifications => _es ? 'Notificaciones' : 'Notifications';
  String get privacy => _es ? 'Privacidad' : 'Privacy';
  String get safety => _es ? 'Seguridad' : 'Safety';
  String get help => _es ? 'Ayuda' : 'Help';
  String get helpAndSafety => _es ? 'Ayuda y Seguridad' : 'Help & Safety';
  String get helpCenter => _es ? 'Centro de ayuda' : 'Help Center';
  String get helpCenterDesc => _es
      ? 'Preguntas frecuentes, soporte y contacto'
      : 'FAQs, support and contact';
  String get safetyCenterDesc => _es
      ? 'Herramientas de seguridad y contactos de confianza'
      : 'Safety tools and trusted contacts';
  String get accountSectionRides => _es ? 'Viajes' : 'Rides';
  String get accountSectionPayments =>
      _es ? 'Pagos y recompensas' : 'Payments & Rewards';
  String get accountSectionSupport =>
      _es ? 'Soporte y seguridad' : 'Support & Safety';
  String get accountSectionAccount => _es ? 'Cuenta' : 'Account';
  String get about => _es ? 'Acerca de' : 'About';
  String get logOut => _es ? 'Cerrar sesión' : 'Log out';
  String get logOutConfirm => _es
      ? '¿Estás seguro de que quieres cerrar sesión?'
      : 'Are you sure you want to log out?';

  // ── Notification Settings ─────────────────────────────────────────────────
  String get notificationsEnabled =>
      _es ? 'Notificaciones Habilitadas' : 'Notifications Enabled';
  String get notificationsDisabled =>
      _es ? 'Notificaciones Deshabilitadas' : 'Notifications Disabled';
  String get allNotificationsOn =>
      _es ? 'Todas las notificaciones activas' : 'All notifications are active';
  String get allNotificationsOff => _es
      ? 'Todas las notificaciones desactivadas'
      : 'All notifications are turned off';
  String get syncedWithPhone => _es
      ? 'Sincronizado con la configuración de tu teléfono'
      : 'Synced with your phone settings';
  String get enableInSettings => _es
      ? 'Habilita en la configuración del teléfono para recibir alertas'
      : 'Enable in phone settings to receive alerts';
  String get pushNotifications =>
      _es ? 'Notificaciones Push' : 'Push Notifications';
  String get rideUpdates => _es ? 'Actualizaciones de Viajes' : 'Ride Updates';
  String get rideUpdatesDesc => _es
      ? 'Notificaciones sobre el estado del viaje, llegada del conductor y finalización del viaje.'
      : 'Get notified about ride status, driver arrival, and trip completion.';
  String get promotionsOffers =>
      _es ? 'Promociones y Ofertas' : 'Promotions & Offers';
  String get promotionsDesc => _es
      ? 'Recibe ofertas especiales, descuentos y recompensas por referidos.'
      : 'Receive special deals, discounts, and referral rewards.';
  String get safetyAlerts => _es ? 'Alertas de Seguridad' : 'Safety Alerts';
  String get safetyAlertsDesc => _es
      ? 'Notificaciones importantes de seguridad durante y después de los viajes.'
      : 'Important safety notifications during and after rides.';
  String get paymentNotif => _es ? 'Pagos' : 'Payment';
  String get paymentNotifDesc => _es
      ? 'Recibos, confirmaciones de pago y actualizaciones de facturación.'
      : 'Receipts, payment confirmations, and billing updates.';
  String get soundAndVibration =>
      _es ? 'Sonido y Vibración' : 'Sound & Vibration';
  String get sounds => _es ? 'Sonidos' : 'Sounds';
  String get soundsDesc =>
      _es ? 'Reproducir sonidos de notificación.' : 'Play notification sounds.';
  String get vibration => _es ? 'Vibración' : 'Vibration';
  String get vibrationDesc =>
      _es ? 'Vibrar con las notificaciones.' : 'Vibrate on notifications.';

  // ── Privacy ───────────────────────────────────────────────────────────────
  String get dataSharing => _es ? 'Compartir Datos' : 'Data Sharing';
  String get locationSharing =>
      _es ? 'Compartir Ubicación' : 'Location Sharing';
  String get locationSharingDesc => _es
      ? 'Comparte tu ubicación con conductores durante viajes para recogidas precisas.'
      : 'Share your location with drivers during rides for accurate pickups.';
  // Android foreground-service notification shown while the driver's
  // location is being published in the background.
  /// Payment screen: keep this method for future rides.
  String get setAsDefaultPayment =>
      _es ? 'Seleccionar como predeterminado' : 'Set as default';
  String get savedAsDefaultPayment =>
      _es ? 'Guardado como predeterminado' : 'Saved as your default';

  /// The wait shown beside the chosen vehicle, and the reason there is none.
  String get ofWait => _es ? 'de espera' : 'of wait';
  String get away => _es ? 'de camino' : 'away';

  /// Shown on the rider's live-location card before the first GPS fix.
  String get syncing => _es ? 'Sincronizando' : 'Syncing';

  String get driverLocationNotifTitle => _es
      ? 'Cruise está compartiendo tu ubicación'
      : 'Cruise is sharing your location';
  String get driverLocationNotifOnTrip => _es
      ? 'Tu pasajero puede ver dónde estás durante el viaje.'
      : 'Your passenger can see where you are during the trip.';
  String get driverLocationNotifOnline => _es
      ? 'Estás en línea y recibiendo viajes.'
      : "You're online and receiving ride requests.";

  String get usageAnalytics => _es ? 'Análisis de Uso' : 'Usage Analytics';
  String get usageAnalyticsDesc => _es
      ? 'Ayúdanos a mejorar la app compartiendo datos de uso anónimos.'
      : 'Help us improve the app by sharing anonymous usage data.';
  String get personalizedAds =>
      _es ? 'Anuncios Personalizados' : 'Personalized Ads';
  String get personalizedAdsDesc => _es
      ? 'Mostrar anuncios basados en tus preferencias e historial de viajes.'
      : 'Show ads based on your ride preferences and history.';
  String get yourData => _es ? 'Tus Datos' : 'Your Data';
  String get clearTripHistory =>
      _es ? 'Borrar Historial de Viajes' : 'Clear Trip History';
  String get clearTripHistoryDesc => _es
      ? 'Eliminar todos los viajes guardados de este dispositivo.'
      : 'Remove all saved trips from this device.';
  String get clearTripHistoryConfirm => _es
      ? 'Esto eliminará permanentemente todo tu historial de viajes guardado en este dispositivo.'
      : 'This will permanently delete all your saved trip history from this device.';
  String get tripHistoryCleared =>
      _es ? 'Historial de viajes borrado' : 'Trip history cleared';
  String get downloadMyData => _es ? 'Descargar Mis Datos' : 'Download My Data';
  String get downloadMyDataDesc => _es
      ? 'Solicitar una copia de todos tus datos personales.'
      : 'Request a copy of all your personal data.';
  String get downloadMyDataConfirm => _es
      ? 'Prepararemos una copia de tus datos personales y la enviaremos a tu correo registrado dentro de 48 horas.'
      : "We'll prepare a copy of your personal data and send it to your registered email address within 48 hours.";
  String get requestExport => _es ? 'Solicitar Exportación' : 'Request Export';
  String get dataExportRequested => _es
      ? 'Exportación solicitada. Recibirás un correo dentro de 48 horas.'
      : "Data export requested. You'll receive an email within 48 hours.";
  String get account => _es ? 'Cuenta' : 'Account';
  String get deleteAccount => _es ? 'Eliminar Cuenta' : 'Delete Account';
  String get deleteAccountDesc => _es
      ? 'Eliminar permanentemente tu cuenta y todos los datos asociados.'
      : 'Permanently remove your account and all associated data.';
  String get deleteAccountConfirm => _es
      ? 'Esto eliminará permanentemente tu cuenta y todos tus datos. Esta acción no se puede deshacer.'
      : 'This will permanently delete your account and all data. This action cannot be undone.';
  String get deleteAccountError => _es
      ? 'No se pudo eliminar tu cuenta. Revisa tu conexión e inténtalo de nuevo.'
      : 'Could not delete your account. Check your connection and try again.';
  String get exportDataAction => _es ? 'Exportar Datos' : 'Export Data';
  String get exportingData =>
      _es ? 'Exportando tus datos...' : 'Exporting your data...';
  String get exportDataSummary => _es
      ? 'Mira un resumen de los datos personales que guardamos sobre ti.'
      : 'View a summary of the personal data we store about you.';
  String get yourDataExport =>
      _es ? 'Tu Exportación de Datos' : 'Your Data Export';
  String get exportTripsLabel => _es ? 'Viajes' : 'Trips';
  String get exportRatingsLabel => _es ? 'Calificaciones' : 'Ratings';
  String get exportConsentLabel =>
      _es ? 'Historial de Consentimiento' : 'Consent History';
  String get joinedLabel => _es ? 'Miembro desde' : 'Joined';
  String tripsOnRecord(int count) =>
      _es ? '$count viaje(s) registrados' : '$count trip(s) on record';
  String ratingsGiven(int count) =>
      _es ? '$count calificación(es) dadas' : '$count rating(s) given';
  String consentRecords(int count) =>
      _es ? '$count registro(s) de consentimiento' : '$count consent record(s)';

  // ── Edit Profile ──────────────────────────────────────────────────────────
  String get changePhoto => _es ? 'Cambiar Foto' : 'Change Photo';
  String get saveChanges => _es ? 'Guardar Cambios' : 'Save Changes';
  String get firstNameRequired =>
      _es ? 'El nombre es requerido' : 'First name is required';
  String get phone => _es ? 'Teléfono' : 'Phone';

  // ── Safety Screen ─────────────────────────────────────────────────────────
  String get safetyTitle => _es ? 'Centro de Seguridad' : 'Safety Hub';
  String get safetySubtitle => _es
      ? 'Tu seguridad es nuestra prioridad.'
      : 'Your safety is our priority.';
  String get safetyFeatures =>
      _es ? 'Características de Seguridad' : 'Safety Features';
  String get shareMyTrip => _es ? 'Compartir mi viaje' : 'Share my trip';
  String get shareMyTripDesc => _es
      ? 'Permite que tus amigos y familia sigan tu viaje en tiempo real.'
      : 'Let friends and family follow your ride in real time.';
  String get verifyYourRide => _es ? 'Verifica tu viaje' : 'Verify your ride';
  String get verifyYourRideDesc => _es
      ? 'Confirma la identidad de tu conductor antes de subir.'
      : "Confirm your driver's identity before getting in.";
  String get trustedContacts =>
      _es ? 'Contactos de Confianza' : 'Trusted contacts';
  String get trustedContactsDesc => _es
      ? 'Elige contactos que puedan seguir tus viajes automáticamente.'
      : 'Choose contacts who can follow your trips automatically.';
  String get rideCheck => 'RideCheck';
  String get rideCheckDesc => _es
      ? 'Detectamos si tu viaje se sale de la ruta y te verificamos.'
      : 'We detect if your trip goes off route and check in on you.';
  String get safetyMinorsPolicy => _es
      ? 'Los pasajeros deben tener al menos 18 años para crear una cuenta. Los menores solo pueden viajar acompañados por un adulto que haya solicitado el viaje o que esté autorizado para acompañar al menor. No se permiten menores no acompañados.'
      : 'Riders must be at least 18 years old to create an account. Minors may ride only when accompanied by an adult who requested the ride or is otherwise authorized to accompany the minor. Unaccompanied minors are not permitted.';
  String get driverMinorsPolicy => _es
      ? 'No transportes menores no acompañados. Los menores solo pueden viajar acompañados por un adulto.'
      : 'Do not transport unaccompanied minors. Minors may ride only when accompanied by an adult.';
  String get rideCheckFullDesc => _es
      ? 'Si tu viaje se desvía de la ruta esperada o toma más tiempo de lo normal, te enviaremos una notificación para verificar que estés bien. También puedes compartir tu ubicación en tiempo real con tus contactos de confianza.'
      : 'If your trip goes off the expected route or takes longer than usual, we\'ll send you a notification to check that you\'re okay. You can also share your real-time location with your trusted contacts.';
  String get shareLocationNow =>
      _es ? 'Compartir ubicación' : 'Share location now';
  String get rideCheckShareText => _es
      ? 'Estoy en un viaje con Cruise App. Puedes verificar que estoy bien contactándome.'
      : 'I\'m on a trip with Cruise App. You can check that I\'m safe by reaching out to me.';
  String get safetyTips => _es ? 'Consejos de Seguridad' : 'Safety Tips';
  String get safetyTip1 => _es
      ? 'Siempre verifica a tu conductor y vehículo antes de entrar.'
      : 'Always verify your driver and vehicle before entering.';
  String get safetyTip2 => _es
      ? 'Comparte tu viaje con un contacto de confianza.'
      : 'Share your trip with a trusted contact.';
  String get safetyTip3 => _es
      ? 'Siéntate en el asiento trasero para mayor privacidad.'
      : 'Sit in the back seat for added personal space.';
  String get safetyTip4 => _es
      ? 'Confía en tu intuición — cancela si algo se siente mal.'
      : 'Trust your instincts — cancel if something feels wrong.';

  // ── Help Screen ───────────────────────────────────────────────────────────
  String get helpTitle => _es ? 'Ayuda' : 'Help';
  String get tripsAndFare => _es ? 'Viajes y Tarifa' : 'Trips & Fare';
  String get chargedIncorrectly =>
      _es ? 'Me cobraron incorrectamente' : 'I was charged incorrectly';
  String get lostItem => _es ? 'Perdí un artículo' : 'I lost an item';
  String get disputeCancellation =>
      _es ? 'Disputar una tarifa de cancelación' : 'Dispute a cancellation fee';
  String get tripDidntHappen =>
      _es ? 'Mi viaje no ocurrió' : "My trip didn't happen";
  String get accountAndPayment => _es ? 'Cuenta y Pago' : 'Account & Payment';
  String get changePaymentMethod =>
      _es ? 'Cambiar método de pago' : 'Change payment method';
  String get cantAccessAccount =>
      _es ? 'No puedo acceder a mi cuenta' : "I can't access my account";
  String get updateEmailPhone =>
      _es ? 'Actualizar mi correo o teléfono' : 'Update my email or phone';
  String get deleteMyAccount =>
      _es ? 'Eliminar mi cuenta' : 'Delete my account';
  String get reportSafetyIssue =>
      _es ? 'Reportar un problema de seguridad' : 'Report a safety issue';
  String get iWasInAccident =>
      _es ? 'Tuve un accidente' : 'I was in an accident';
  String get unsafeDriver => _es
      ? 'Mi conductor me hizo sentir inseguro'
      : 'My driver made me feel unsafe';
  String get usingTheApp => _es ? 'Usando la Aplicación' : 'Using the App';
  String get gpsIssues =>
      _es ? 'Problemas de GPS / ubicación' : 'GPS / location issues';
  String get notReceivingNotifications =>
      _es ? 'No recibo notificaciones' : 'Not receiving notifications';
  String get mapNotLoading => _es ? 'El mapa no carga' : 'Map not loading';

  // ── About Screen ──────────────────────────────────────────────────────────
  String versionText(String version, String build) => _es
      ? 'Versión $version (Compilación $build)'
      : 'Version $version (Build $build)';
  String get termsOfService =>
      _es ? 'Términos de Servicio' : 'Terms of Service';
  String get privacyPolicy => _es ? 'Política de Privacidad' : 'Privacy Policy';
  String get openSourceLicenses =>
      _es ? 'Licencias de Código Abierto' : 'Open Source Licenses';
  String get rateApp => _es ? 'Calificar la Aplicación' : 'Rate the App';
  String get shareCruise => _es ? 'Compartir Cruise' : 'Share Cruise';
  String get madeWithHeart =>
      _es ? 'Hecho con ❤ en Miami' : 'Made with ❤ in Miami';
  String get copyright => '@2026 Cruiseinride';
  String get thankYou =>
      _es ? '¡Gracias por tu apoyo! ⭐' : 'Thank you for your support! ⭐';

  // ── Identity Verification ─────────────────────────────────────────────────
  String get verifyIdentity =>
      _es ? 'Verifica tu Identidad' : 'Verify Your Identity';
  String get verifyIdentitySubtitle => _es
      ? 'Para garantizar la seguridad de todos los pasajeros y conductores, necesitamos verificar tu identidad.'
      : 'To ensure the safety of all riders and drivers, we need to verify your identity.';
  String get scanLicenseFront =>
      _es ? 'Escanea el frente de tu licencia' : 'Scan front of your license';
  String get scanLicenseBack =>
      _es ? 'Escanea el dorso de tu licencia' : 'Scan back of your license';
  String get startVerification =>
      _es ? 'Iniciar Verificación' : 'Start Verification';
  String get submittingVerification =>
      _es ? 'Enviando Verificación' : 'Submitting Verification';
  String get encryptingUploading => _es
      ? 'Encriptando y cargando tus documentos de forma segura...'
      : 'Encrypting and securely uploading your documents...';
  String get identityVerified =>
      _es ? '¡Identidad Verificada!' : 'Identity Verified!';
  String get youAreVerified => _es ? '¡Estás verificado!' : "You're verified!";
  String get pendingReview => _es ? 'Pendiente de Revisión' : 'Pending Review';
  String get pendingReviewDesc => _es
      ? 'Tu verificación está siendo revisada por nuestro equipo.'
      : 'Your verification is being reviewed by our team.';
  String get verificationRejected =>
      _es ? 'Verificación No Aprobada' : 'Verification Not Approved';
  String get tryAgain => _es ? 'Intentar de Nuevo' : 'Try Again';

  // ── Notifications Onboarding ──────────────────────────────────────────────
  String get notifOnboardingTitle =>
      _es ? 'Ayúdanos a mantenerte\ninformado' : 'Help us keep you\ninformed';
  String get notifOnboardingSubtitle => _es
      ? 'Permite notificaciones para obtener\nactualizaciones de viajes en tiempo real\ne información útil sobre tu cuenta'
      : 'Allow notifications to get real-time ride\nupdates and helpful information about your\naccount';
  String get allow => _es ? 'Permitir' : 'Allow';

  // ── Payment Method ────────────────────────────────────────────────────────
  String get addPaymentMethod =>
      _es ? 'Añadir Método de Pago' : 'Add Payment Method';
  String get addedPaymentMethods =>
      _es ? 'Métodos de Pago Agregados' : 'Added Payment Methods';
  String get addDebitCreditCardAction =>
      _es ? 'Agregar tarjeta de débito/crédito' : 'Add Debit/Credit Card';
  String get selectPaymentMethod =>
      _es ? 'Elige un método de pago' : 'Choose a payment method';
  String get creditDebitCard =>
      _es ? 'Tarjeta de crédito o débito' : 'Credit or debit card';

  // ── Ride History ──────────────────────────────────────────────────────────
  String get yourTrips => _es ? 'Tus Viajes' : 'Your Trips';
  String get noTripsYet => _es ? 'Sin viajes aún' : 'No trips yet';
  String get noTripsSubtitle => _es
      ? 'Tu historial de viajes aparecerá aquí'
      : 'Your ride history will appear here';

  // ── Ride Rating ───────────────────────────────────────────────────────────
  String get howWasRide => _es ? '¿Cómo fue tu viaje?' : 'How was your ride?';
  String rateExperience(String name) => _es
      ? 'Califica tu experiencia con $name'
      : 'Rate your experience with $name';
  String get addTip => _es ? 'Añadir propina' : 'Add a tip';
  String get tipGoesToDriver =>
      _es ? 'El 100% va a tu conductor' : '100% goes to your driver';
  String get noTip => _es ? 'Sin propina' : 'No tip';
  String get leaveComment =>
      _es ? 'Deja un comentario (opcional)' : 'Leave a comment (optional)';

  // ── Rider Tracking ────────────────────────────────────────────────────────
  String get driverAssigned => _es ? 'Conductor Asignado' : 'Driver Assigned';
  String driverOnWay(String driver, String color, String model) => _es
      ? '$driver está en camino en un $color $model'
      : '$driver is on the way in a $color $model';
  String get arrivingSoon => _es ? 'Llegando pronto' : 'Arriving soon';
  String get driverArrived =>
      _es ? 'El conductor ha llegado' : 'Driver has arrived';

  // ── Chat ──────────────────────────────────────────────────────────────────
  String get chat => 'Chat';
  String get typeMessage => _es ? 'Escribe un mensaje...' : 'Type a message...';
  String newMessagesFromDriver(int count) => _es
      ? '$count nuevo${count > 1 ? "s" : ""} mensaje${count > 1 ? "s" : ""} del conductor'
      : '$count new message${count > 1 ? "s" : ""} from driver';
  String get newMessageFromDriverPushTitle =>
      _es ? 'Nuevo mensaje del conductor' : 'New message from driver';

  // ── Trip Receipt ──────────────────────────────────────────────────────────
  String get tripReceipt => _es ? 'Recibo del Viaje' : 'Trip Receipt';
  String get rideCompleted => _es ? 'Viaje Completado' : 'Ride Completed';
  String get total => 'Total';
  String get sendReceipt => _es ? 'Enviar Recibo' : 'Send Receipt';
  String receiptSentTo(String email) =>
      _es ? 'Recibo enviado a $email' : 'Receipt sent to $email';
  String get noEmailError => _es
      ? 'No se encontró dirección de correo. Por favor actualiza tu perfil.'
      : 'No email address found. Please update your profile.';

  // ── Scheduled Rides ───────────────────────────────────────────────────────
  String get scheduledRides => _es ? 'Viajes Programados' : 'Scheduled Rides';
  String get cancelRideQuestion => _es ? '¿Cancelar Viaje?' : 'Cancel Ride?';
  String get cancelRideConfirm => _es
      ? '¿Estás seguro de que deseas cancelar este viaje programado?'
      : 'Are you sure you want to cancel this scheduled ride?';
  String get keep => _es ? 'Mantener' : 'Keep';
  String get rideCancelled =>
      _es ? 'Viaje cancelado exitosamente' : 'Ride canceled successfully';
  String get rideCancelledByDriver =>
      _es ? 'Viaje cancelado' : 'Ride Cancelled';
  String get driverCancelledMessage => _es
      ? 'Tu conductor ha cancelado el viaje. Por favor solicita otro viaje.'
      : 'Your driver has cancelled the ride. Please request another ride.';
  String get connectionLost => _es
      ? 'Conexión perdida — reconectando…'
      : 'Connection lost — reconnecting…';

  // ── Inbox ─────────────────────────────────────────────────────────────────
  String get inbox => _es ? 'Bandeja de Entrada' : 'Inbox';
  String get messages => _es ? 'Mensajes' : 'Messages';

  // ── Forgot Password ───────────────────────────────────────────────────────
  String get forgotPasswordTitle =>
      _es ? '¿Olvidaste tu contraseña?' : 'Forgot password?';
  String get resetPassword => _es ? 'Restablecer contraseña' : 'Reset password';
  String get forgotSubtitle => _es
      ? 'Introduce tu correo o teléfono y te enviaremos un código de 6 dígitos para restablecer tu contraseña.'
      : "Enter your email or phone and we'll send you a 6-digit code to reset your password.";
  String get resetCodeSentGeneric => _es
      ? 'Si existe una cuenta con ese correo o teléfono, el código va en camino.'
      : 'If an account exists for that email or phone, a code is on its way.';
  String get identifierNotFound => _es
      ? 'Correo o número de teléfono no encontrado'
      : 'Email or phone number not found';
  String get codeSentViaEmail => _es ? 'por correo' : 'by email';
  String get codeSentViaSms => _es ? 'por SMS' : 'by SMS';
  String get resetCodeSubtitle => _es
      ? 'Introduce el código de 6 dígitos que te enviamos y tu nueva contraseña.'
      : 'Enter the 6-digit code we sent and your new password.';
  String get sendResetLink => _es ? 'Enviar enlace' : 'Send reset link';
  String get sendCode => _es ? 'Enviar Código' : 'Send code';
  String get resendCode => _es ? 'Reenviar código' : 'Resend code';
  String get newPassword => _es ? 'Nueva contraseña' : 'New password';
  String get resetPasswordBtn =>
      _es ? 'Restablecer contraseña' : 'Reset password';
  String get resetSuccess => _es
      ? 'Contraseña restablecida exitosamente. Por favor inicia sesión.'
      : 'Password reset successfully. Please sign in.';
  String get resetLinkSent => _es
      ? 'Te enviamos un enlace para restablecer tu contraseña. Revisa tu correo electrónico.'
      : 'We sent you a password reset link. Check your email.';
  String get noAccountFound => _es
      ? 'No se encontró ninguna cuenta registrada con este correo.'
      : 'No registered account found with this email.';
  String get backToSignIn =>
      _es ? 'Volver a iniciar sesión' : 'Back to sign in';
  String get resumeOnline => _es ? 'REANUDAR' : 'RESUME';

  // ── Verify Code ───────────────────────────────────────────────────────────
  String get codeSentCheckPhone => _es
      ? 'Código enviado — revisa\ntu teléfono'
      : 'Code sent — check your\nphone';
  String get codeSentCheckEmail => _es
      ? 'Código enviado — revisa\ntu correo'
      : 'Code sent — check your\nemail';
  String codeSentTo(String dest) =>
      _es ? 'Enviamos un código a $dest' : 'We sent a code to $dest';

  // ── Promo Codes ───────────────────────────────────────────────────────────
  String get promoCodes => _es ? 'Códigos Promocionales' : 'Promo Codes';
  String get enterPromoCode =>
      _es ? 'Introduce código promocional' : 'Enter promo code';
  String get promoAlreadyAdded =>
      _es ? 'Código promocional ya añadido' : 'Promo code already added';
  String get promoInvalid => _es
      ? 'No se pudo validar el código promocional'
      : 'Could not validate promo code';

  // ── Map Picker ────────────────────────────────────────────────────────────
  String get moveMapHint => _es
      ? 'Mueve el mapa para elegir una ubicación'
      : 'Move the map to pick a location';
  String get pinnedLocation => _es ? 'Ubicación fija' : 'Pinned location';

  // ── License Scanner ───────────────────────────────────────────────────────
  String get scanFrontLicense =>
      _es ? 'Escanea el Frente de la Licencia' : 'Scan Front of License';
  String get scanBackLicense =>
      _es ? 'Escanea el Dorso de la Licencia' : 'Scan Back of License';
  String get alignLicenseHint => _es
      ? 'Alinea tu licencia dentro del marco y toca el botón para escanear'
      : 'Align your license within the frame and tap the button to scan';
  String get usePhoto => _es ? 'Usar Foto' : 'Use Photo';
  String get retake => _es ? 'Reintentar' : 'Retake';
  String get cameraPermissionRequired => _es
      ? 'Se requiere permiso de cámara para escanear tu licencia'
      : 'Camera permission is required to scan your license';

  // ── Permission Dialogs ────────────────────────────────────────────────────
  String get locationPermissionRequired =>
      _es ? 'Permiso de Ubicación Requerido' : 'Location Permission Required';
  String get locationPermissionPermanentlyDeniedMsg => _es
      ? 'El permiso de ubicación fue denegado permanentemente. Por favor habilítalo en la configuración de tu teléfono.'
      : 'Location permission is permanently denied. Please enable it in your phone settings.';
  String get locationServicesDisabledMsg => _es
      ? 'Los servicios de ubicación están desactivados. Por favor actívalos para continuar.'
      : 'Location services are disabled. Please enable them to continue.';
  String get openSettings => _es ? 'Abrir Configuración' : 'Open Settings';
  String get cameraPermissionPermanentlyDenied =>
      _es ? 'Permiso de Cámara Requerido' : 'Camera Permission Required';
  String get cameraPermissionPermanentlyDeniedMsg => _es
      ? 'El permiso de cámara fue denegado permanentemente. Por favor habilítalo en la configuración de tu teléfono.'
      : 'Camera permission is permanently denied. Please enable it in your phone settings.';
  String get locationRequiredForDriver => _es
      ? 'La ubicación es necesaria para recibir viajes y aparecer en línea.'
      : 'Location is required to receive trips and appear online.';

  // ── Driver Screens ────────────────────────────────────────────────────────
  String get personalInformation =>
      _es ? 'Información Personal' : 'Personal information';
  String get personalInfoSubtitle =>
      _es ? 'Cuéntanos un poco sobre ti' : 'Tell us a bit about yourself';
  String get dateOfBirth => _es ? 'Fecha de nacimiento' : 'Date of birth';
  // Per-field red guide shown above the box while it is still missing
  String get fieldHintFirstName =>
      _es ? 'Coloca tu nombre' : 'Enter your first name';
  String get fieldHintLastName =>
      _es ? 'Coloca tu apellido' : 'Enter your last name';
  String get fieldHintDob =>
      _es ? 'Coloca tu fecha de nacimiento' : 'Enter your date of birth';
  String get fieldHintEmail =>
      _es ? 'Coloca tu correo electrónico' : 'Enter your email address';
  String get fieldHintPhone =>
      _es ? 'Coloca tu número de teléfono' : 'Enter your phone number';
  String get fieldHintPassword =>
      _es ? 'Crea una contraseña' : 'Create a password';
  String get fieldHintConfirmPassword =>
      _es ? 'Confirma tu contraseña' : 'Confirm your password';
  String get driverAgeRequirement => _es
      ? 'Debes tener al menos 21 años para conducir con Cruise.'
      : 'You must be at least 21 years old to drive with Cruise.';
  String get driverAgeTooYoung => _es
      ? 'Lo sentimos, debes tener al menos 21 años para registrarte como conductor.'
      : 'Sorry, you must be at least 21 years old to sign up as a driver.';
  String get vehicleDetails =>
      _es ? 'Detalles del Vehículo' : 'Vehicle details';
  String get vehicleInfoSubtitle => _es
      ? 'Añade información sobre tu vehículo'
      : 'Add info about your vehicle';
  String get documentsVerification =>
      _es ? 'Documentos y Verificación' : 'Documents & Verification';
  String get reviewSubmit => _es ? 'Revisar y Enviar' : 'Review & Submit';
  String get submitApplication =>
      _es ? 'Enviar solicitud' : 'Submit application';
  String get driverLicenseFront =>
      _es ? 'Licencia de Conducir — FRENTE' : "Driver's License — FRONT";
  String get driverLicenseBack =>
      _es ? 'Licencia de Conducir — DORSO' : "Driver's License — BACK";
  String get tapToScanFront => _es
      ? 'Toca para escanear el frente de tu licencia'
      : 'Tap to scan the front of your license';
  String get tapToScanBack => _es
      ? 'Toca para escanear el dorso de tu licencia'
      : 'Tap to scan the back of your license';
  String get carInsurance => _es ? 'Seguro de Auto' : 'Car Insurance';
  String get carInsuranceDesc => _es
      ? 'Tarjeta o póliza de seguro vigente'
      : 'Current insurance card or policy page';
  String get socialSecurityNumber =>
      _es ? 'Número de Seguro Social' : 'Social Security Number';
  String get emailAddress => _es ? 'Dirección de correo' : 'Email address';
  String get driverPasswordLabel => _es
      ? 'Contraseña (8+ caracteres, número, mayúscula, símbolo)'
      : 'Password (8+ chars, number, uppercase, symbol)';
  String get make => _es ? 'Marca' : 'Make';
  String get model => _es ? 'Modelo' : 'Model';
  String get year => _es ? 'Año' : 'Year';
  String get color => _es ? 'Color' : 'Color';
  String get licensePlate => _es ? 'Placa' : 'License Plate';

  // ── Driver Login ──────────────────────────────────────────────────────────
  String get driverSignIn =>
      _es ? 'Iniciar sesión como Conductor' : 'Sign in as Driver';
  String get noAccountSignUp =>
      _es ? '¿Sin cuenta? Regístrate' : "Don't have an account? Sign up";
  String get accountBlocked =>
      _es ? 'Tu cuenta ha sido bloqueada' : 'Your account has been blocked';
  String get accountDeactivated => _es
      ? 'Tu cuenta ha sido desactivada'
      : 'Your account has been deactivated';

  // ── Driver Home / Online ──────────────────────────────────────────────────
  String get goOnline => _es ? 'Conectarse' : 'GO ONLINE';
  String get verifyFirst => _es ? 'VERIFICA PRIMERO' : 'VERIFY FIRST';
  String get goOffline => _es ? 'Desconectarse' : 'Go Offline';
  String get youreOffline => _es ? 'Estás desconectado' : "You're offline";
  String get goOnlineToEarn =>
      _es ? 'Conéctate para empezar a ganar' : 'Go online to start earning';
  String get tapGoForTrips => _es
      ? 'Toca IR para encontrar viajes cercanos'
      : 'Tap GO to find trips nearby';
  String get today => _es ? 'Hoy' : 'Today';
  String get weekLabel => _es ? 'Semana' : 'Week';
  String get monthLabel => _es ? 'Mes' : 'Month';
  String get seeMore => _es ? 'Ver más' : 'See more';
  String get tripsLabel => _es ? 'Viajes' : 'Trips';
  String get onlineLabel => _es ? 'En Línea' : 'Online';
  String get recommendedForYou =>
      _es ? 'Recomendado para ti' : 'Recommended for you';
  String get earningsToday => _es ? 'Ganancias de Hoy' : "Today's Earnings";
  String get tripsToday => _es ? 'Viajes Hoy' : 'Trips Today';
  String get hoursOnline => _es ? 'Horas en Línea' : 'Hours Online';
  String get findingTrips => _es ? 'Buscando viajes' : 'Finding trips';
  String get youreOnlineStatus => _es ? 'Estás en línea' : "You're online";
  String get safetyHub => _es ? 'Seguridad' : 'Safety';
  String get reservedLabel => _es ? 'Reservas' : 'Reserved';
  String get noScheduledNearby =>
      _es ? 'No hay viajes programados' : 'No scheduled trips';
  String get noScheduledNearbySub => _es
      ? 'Aparecerán aquí cuando alguien reserve un viaje'
      : 'They show up here when someone books and reserves a ride';

  /// Subtitle for the other half of the same card — when there *are* rides.
  /// [noScheduledNearbySub] was shown in both states, so a driver looking at
  /// "3 viajes reservados" was told underneath that they would appear when
  /// someone booked one.
  String get scheduledNearbySub => _es
      ? 'Elige el que te quede de camino'
      : 'Pick the one that fits your route';
  String get scheduledNearbyCount =>
      _es ? 'viajes reservados' : 'rides reserved';
  String get scheduledNearbyCountOne =>
      _es ? 'viaje reservado' : 'ride reserved';
  String get viewAllScheduled => _es ? 'Ver todos' : 'View all';

  /// Shown when the claim is refused because the pickup is in another state.
  /// The backend sends this reason in English; the driver reads it here.
  /// Somebody else claimed it first. Not an error the driver caused, and
  /// not something they can retry — the ride is simply gone.
  // ── How long ago a notification arrived ──
  //
  // Past an hour it reads "1 h 5 min", not "1h". A driver checking why
  // their rating moved wants to line the notice up against a trip they
  // remember, and an hour rounded off cannot be lined up against
  // anything.
  String get agoJustNow => _es ? 'Ahora mismo' : 'Just now';
  String agoMinutes(int m) => _es ? 'Hace $m min' : '$m min ago';
  String agoHours(int h) => _es ? 'Hace $h h' : '$h h ago';
  String agoHoursMinutes(int h, int m) =>
      _es ? 'Hace $h h $m min' : '$h h $m min ago';
  String get agoYesterday => _es ? 'Ayer' : 'Yesterday';
  String agoDays(int d) => _es ? 'Hace $d días' : '$d days ago';
  String agoWeeks(int w) => _es
      ? (w == 1 ? 'Hace una semana' : 'Hace $w semanas')
      : (w == 1 ? 'A week ago' : '$w weeks ago');

  String get scheduledRideTaken => _es
      ? 'Ese viaje programado ya no está disponible — otro conductor lo tomó primero.'
      : 'That scheduled ride is no longer available — another driver took it first.';

  String get scheduledOutOfState => _es
      ? 'Esta reserva es de otro estado. Solo puedes aceptar reservas del estado donde estás activo.'
      : 'This reservation is in another state. You can only take reservations in the state you are active in.';
  String get tripRequest => _es ? 'Solicitud de Viaje' : 'Trip Request';
  String get accept => _es ? 'Aceptar' : 'Accept';

  // ── Password reset, in-app ──
  // `forgotPassword` already exists up in the sign-in block; this reuses it
  // rather than declaring a second one with the same words.
  String get resetPasswordTitle =>
      _es ? 'Cambiar contraseña' : 'Reset password';
  String get resetCodeSent => _es ? 'Revisa tu correo' : 'Check your email';
  String get resetSending => _es ? 'Enviando…' : 'Sending…';
  String resetCodeSentTo(String email) => _es
      ? 'Enviamos un código de verificación a $email. Escríbelo aquí abajo.'
      : 'We sent a verification code to $email. Type it in below.';
  String get resetResend => _es ? 'Enviar otro código' : 'Send another code';
  String resetResendIn(int seconds) => _es
      ? 'Puedes pedir otro en ${seconds}s'
      : 'You can ask for another in ${seconds}s';
  String get resetChooseNew =>
      _es ? 'Elige tu contraseña nueva' : 'Choose your new password';
  String get resetPasswordRules => _es
      ? 'Mínimo 8 caracteres, con una mayúscula, un número y un símbolo.'
      : 'At least 8 characters, with a capital letter, a number and a '
          'symbol.';
  String get newPasswordLabel => _es ? 'Contraseña nueva' : 'New password';
  String get confirmPasswordLabel =>
      _es ? 'Confirmar contraseña' : 'Confirm password';
  String get passwordsDoNotMatch =>
      _es ? 'Las contraseñas no coinciden' : 'The passwords do not match';
  String get passwordChanged =>
      _es ? 'Contraseña actualizada' : 'Password updated';
  String get continueLabel => _es ? 'Continuar' : 'Continue';
  String get decline => _es ? 'Rechazar' : 'Decline';

  // ── Driver Menu / Profile / Settings ──────────────────────────────────────
  String get menu => _es ? 'Menú' : 'Menu';
  String get profile => _es ? 'Perfil' : 'Profile';
  String get tier => _es ? 'Nivel' : 'Tier';
  String get rating => _es ? 'Calificación' : 'Rating';
  String get satisfactionRate =>
      _es ? 'Tasa de Satisfacción' : 'Satisfaction Rate';
  String get acceptanceRate => _es ? 'Tasa de Aceptación' : 'Acceptance Rate';
  String get cancellationRate =>
      _es ? 'Tasa de Cancelación' : 'Cancellation Rate';
  String get onTimeRate => _es ? 'Tasa de Puntualidad' : 'On-Time Rate';
  String get totalTrips => _es ? 'Viajes Totales' : 'Total Trips';
  String get settings => _es ? 'Configuración' : 'Settings';
  String get general => 'General';
  String get manageAccount => _es ? 'Administrar cuenta' : 'Manage account';
  String get nightMode => _es ? 'Modo Nocturno' : 'Night Mode';
  String get accessibility => _es ? 'Accesibilidad' : 'Accessibility';

  // ── Profile Review Gender ─────────────────────────────────────────────────
  String get selectGender => _es ? 'Seleccionar género' : 'Select gender';
  String get men => _es ? 'Hombre' : 'Men';
  String get women => _es ? 'Mujer' : 'Women';
  String get nonbinary => 'Nonbinary';
  String get preferNotToSay => _es ? 'Prefiero no decir' : 'Prefer not to say';

  // ── Help Screen ───────────────────────────────────────────────────────────
  String get helpAndSupport => _es ? 'Ayuda y Soporte' : 'Help & Support';
  String get howCanWeHelp =>
      _es ? '¿Cómo podemos ayudarte hoy?' : 'How can we help you today?';
  String get searchHelpTopics =>
      _es ? 'Buscar temas de ayuda...' : 'Search for help topics...';
  String get contactSupport => _es ? 'Contactar Soporte' : 'Contact Support';
  String get supportConversationDesc => _es
      ? 'Tus mensajes con el equipo de soporte'
      : 'Your messages with the support team';
  String get emailSupport => _es ? 'Correo Electrónico' : 'Email';
  String get callSupport => _es ? 'Llamar' : 'Call';
  String get noResultsFound =>
      _es ? 'No se encontraron resultados' : 'No results found';
  String get tryDifferentSearch =>
      _es ? 'Intenta con un término diferente' : 'Try a different search term';
  String get stillNeedHelp =>
      _es ? '¿Aún necesitas ayuda?' : 'Still need help?';
  String get supportAvailable247 => _es
      ? 'Nuestro equipo de soporte está disponible 24/7 para ayudarte.'
      : 'Our support team is available 24/7 to assist you.';
  String get liveChat => _es ? 'Chat en Vivo' : 'Live Chat';

  // ── Home Screen ───────────────────────────────────────────────────────────
  String get fastRide => _es ? 'Prioritario' : 'Priority';
  String get schedule => _es ? 'Programar' : 'Schedule';
  String get recentActivity => _es ? 'Actividad Reciente' : 'Recent Activity';
  String get noServiceState => _es
      ? 'No hay servicios disponibles en tu estado actualmente.'
      : 'No services available in your state at this time.';
  String get understood => _es ? 'Entendido' : 'OK';
  String get fastRideUnavailable => _es
      ? 'Prioritario solo está disponible cuando hay conductores en línea cerca. Intenta de nuevo en unos minutos.'
      : 'Priority is only available when drivers are online nearby. Please try again in a few minutes.';
  String get fastRideUnavailableTitle =>
      _es ? 'Prioritario No Disponible' : 'Priority Unavailable';
  String get serviceZoneTitle =>
      _es ? 'Zona no disponible' : 'Zone Not Available';
  String get noDriversInState => _es
      ? 'No hay conductores disponibles en este estado'
      : 'No drivers available in this state';
  String get rideLabel => _es ? 'Viajar' : 'Ride';
  String get accountLabel => _es ? 'Cuenta' : 'Account';
  String get verifyIdentityToRide => _es
      ? 'Verifica tu identidad para pedir viajes'
      : 'Verify identity to request rides';
  String get chooseRideType => _es ? 'Elige tipo de viaje' : 'Choose ride type';
  String get airportLabel => _es ? 'Aeropuerto' : 'Airport';
  String get airportSubtitle => _es
      ? 'Reserva un viaje al aeropuerto o desde él'
      : 'Book a ride to or from the airport';
  String get scheduleSubtitle =>
      _es ? 'Programa un viaje para después' : 'Schedule a ride for later';

  // ── Home Screen Additional ─────────────────────────────────────────────────
  String get rideInProgressTitle => _es ? 'Viaje en curso' : 'Ride in progress';
  String get rideInProgressSubtitle => _es
      ? 'Toca para continuar tu viaje actual'
      : 'Tap to resume your current ride';
  String get chooseRide => _es ? 'Elige un viaje' : 'Choose a Ride';
  String get pickYourOption => _es ? 'Elige tu opción' : 'Pick your option';
  String get homeLabel => _es ? 'Casa' : 'Home';
  String get workLabel => _es ? 'Trabajo' : 'Work';
  String get addLabel => _es ? 'Agregar' : 'Add';
  String get place1Label => _es ? 'Lugar 1' : 'Place 1';
  String get place2Label => _es ? 'Lugar 2' : 'Place 2';
  String get promoTripsLabel => _es ? 'viajes' : 'rides';
  String get editAddressLabel => _es ? 'Editar Dirección' : 'Edit Address';
  String get requestRideLabel => _es ? 'Solicitar Viaje' : 'Request a Ride';
  String get promoOff => _es ? '10% desc' : '10% off';
  String get promoTrips => _es ? 'viajes' : 'rides';
  String get whereTo => _es ? '¿A dónde?' : 'Where to?';

  // ── Ride Request ──────────────────────────────────────────────────────────
  String get comfortableSedan => _es ? 'Sedán cómodo' : 'Comfortable sedan';
  String get pleaseSelectDateTime => _es
      ? 'Por favor selecciona fecha y hora para tu viaje programado'
      : 'Please select a date and time for your scheduled ride';
  String get cannotSchedulePast => _es
      ? 'No se puede programar un viaje en el pasado. Selecciona una fecha y hora futuras.'
      : 'Cannot schedule a ride in the past. Please select a future date and time.';
  String get schedule30MinAdvance => _es
      ? 'Los viajes programados deben ser con al menos 30 minutos de anticipación'
      : 'Scheduled rides must be at least 30 minutes in advance';
  String get scheduleMax30Days => _es
      ? 'No se pueden programar viajes con más de 30 días de anticipación'
      : 'Cannot schedule rides more than 30 days in advance';

  // ── Login Verify ──────────────────────────────────────────────────────────
  String get connectionError => _es
      ? 'Error de conexión — ¿está el servidor activo?'
      : 'Connection error — is the server running?';
  String get verifyAndSignIn =>
      _es ? 'Verificar e Iniciar Sesión' : 'Verify & Sign In';
  String enterCodeSentTo(String contact) => _es
      ? 'Introduce el código enviado a $contact.'
      : 'Enter the code sent to $contact.';

  // ── Ride Options ──────────────────────────────────────────────────────────
  String get confirmRide => _es ? 'Confirmar Viaje' : 'Confirm Ride';
  String confirmRideWithDetails(String name, String price) =>
      _es ? 'Confirmar $name · $price' : 'Confirm $name · $price';

  // ── Rider Tracking ────────────────────────────────────────────────────────
  String get friendlyDriver => _es ? 'Conductor amigable' : 'Friendly driver';
  String get cleanCar => _es ? 'Auto limpio' : 'Clean car';
  String get goodDriving => _es ? 'Buen manejo' : 'Good driving';
  String get aboveAndBeyond => _es ? 'Se esforzó más' : 'Above and beyond';
  String get greatMusic => _es ? 'Buena música' : 'Great music';
  String get goodConversation =>
      _es ? 'Buena conversación' : 'Good conversation';
  String get minLabel => _es ? 'Min' : 'Min';
  String get yourDriverArrived =>
      _es ? 'Tu conductor ha llegado' : 'Your driver has arrived';
  String get yourDriverArrivedExcl =>
      _es ? '¡Tu conductor ha llegado!' : 'Your driver has arrived!';
  String driverWaitingAt(String firstName, String color, String model) => _es
      ? '$firstName te espera en el punto de recogida en un $color $model.'
      : '$firstName is waiting at the pickup spot in a $color $model.';
  String get onTripToDestination =>
      _es ? 'En viaje al destino' : 'On trip to destination';
  String get driverEnRoute =>
      _es ? 'Tu conductor está en camino' : 'Your driver is on the way';
  String get driverEnRouteHeader =>
      _es ? 'Conductor en camino' : 'Driver on the way';
  String get typeAMessage =>
      _es ? 'Escribe un mensaje...' : 'Type a message...';
  String get onTheWayToDestination =>
      _es ? 'En camino a tu destino' : 'On the way to your destination';
  String get driverIsWaitingForYou =>
      _es ? '¡El conductor te está esperando!' : 'Driver is waiting for you!';
  String get driverHasArrived =>
      _es ? 'Tu conductor ha llegado' : 'Your driver has arrived';
  String get onWayToDestination =>
      _es ? 'En camino a tu destino' : 'On the way to your destination';
  String get arrivingAtDestination =>
      _es ? 'Llegando a tu destino' : 'Arriving at your destination';
  String get driverOnTheWayCard =>
      _es ? 'Conductor en camino' : 'Driver on the way';
  String get driverAlmostHereCard =>
      _es ? 'Tu conductor está casi aquí' : 'Your driver is almost here';
  String get driverArrivingCard =>
      _es ? '¡Tu conductor está llegando!' : 'Your driver is arriving!';
  String get driverAtPickupSpot => _es
      ? 'Tu conductor está en el punto de recogida 📍'
      : 'Your driver is at the pickup spot 📍';
  String get driverWaitingAtPickup =>
      _es ? '¡El conductor te está esperando!' : 'Driver is waiting for you!';
  String get driverWaitingForYou =>
      _es ? 'Tu conductor te está esperando' : 'Your driver is waiting for you';
  String get onWayToDestinationCard =>
      _es ? 'En camino a tu destino' : 'On the way to your destination';
  String get arrivingAtDestinationCard =>
      _es ? 'Llegando a tu destino' : 'Arriving at your destination';
  String get waitingForDriver =>
      _es ? 'Buscando conductor...' : 'Looking for a driver...';
  String get waitingForDriverCard =>
      _es ? 'Esperando conductor...' : 'Waiting for driver...';
  String get youHaveArrived => _es ? '¡Has llegado!' : 'You have arrived!';
  String get whatWentWell => _es ? '¿Qué salió bien?' : 'What went well?';
  String get showMore => _es ? 'Mostrar más' : 'Show more';
  String get showLess => _es ? 'Mostrar menos' : 'Show less';
  String get pickupLocation => _es ? 'Lugar de recogida' : 'Pickup location';
  String get destinationLabel => _es ? 'Destino' : 'Destination';
  String get driverArriveInstruction => _es
      ? 'El conductor llegará al mismo lado de la calle que tu punto de recogida'
      : 'Driver will arrive on the same side of the street as your pickup spot';
  String get topRatedDriver =>
      _es ? 'Conductor mejor valorado' : 'Top-rated driver';
  String get leaveAnonymousFeedback =>
      _es ? 'Dejar comentario anónimo' : 'Leave anonymous feedback';
  String get favoriteThisDriver =>
      _es ? 'Agregar conductor como favorito' : 'Favorite this driver';
  String get favoriteDriverNote => _es
      ? 'Priorizaremos a tus conductores favoritos para viajes programados'
      : "We'll prioritize your favorite drivers for scheduled rides";
  String get meetDriverAtPickup => _es
      ? 'Encuéntrate con el conductor en el punto de recogida en'
      : 'Meet driver at pickup spot on';
  String get enterCustomAmount =>
      _es ? 'Ingresar monto personalizado' : 'Enter custom amount';
  String get cancelCustomTip =>
      _es ? 'Cancelar propina personalizada' : 'Cancel custom tip';
  String messageDriver(String name) =>
      _es ? 'Mensaje para $name' : 'Message $name';
  String tipFor(String name) =>
      _es ? 'Tu propina para $name' : 'Your tip for $name';

  // ── Pickup Dropoff Search ──────────────────────────────────────────────────
  String get currentLocationDefault =>
      _es ? 'Ubicación actual' : 'Current location';
  String get chooseOnMap => _es ? 'Elegir en mapa' : 'Choose on map';
  String get setHomeAddress =>
      _es ? 'Establecer dirección de casa' : 'Set home address';
  String get setWorkAddress =>
      _es ? 'Establecer dirección de trabajo' : 'Set work address';
  String get pickLocationOnMap =>
      _es ? 'Elige ubicación en el mapa' : 'Pick location on map';
  String get setAddressFor =>
      _es ? 'Establecer dirección para' : 'Set address for';
  String searchAddressFor(String place) =>
      _es ? 'Buscar dirección para $place' : 'Search address for $place';
  String get typeToSearchAddress =>
      _es ? 'Escribe para buscar dirección' : 'Type to search address';
  String get cancelTripConfirm => _es
      ? '¿Estás seguro de que deseas cancelar este viaje?'
      : 'Are you sure you want to cancel this trip?';
  String get cancelFeeWarning => _es
      ? 'Se te puede cobrar una tarifa de cancelación.'
      : 'You may be charged a cancellation fee.';
  String get yesCancelTrip => _es ? 'Sí, Cancelar Viaje' : 'Yes, Cancel Trip';
  String get cancelAfterAssignBody => _es
      ? 'Tu conductor ya va en camino. Puedes cancelar al instante: es gratis dentro de los primeros 2 minutos después de la asignación del conductor; después aplica una tarifa de cancelación de \$5.00.'
      : 'Your driver is already on the way. You can cancel instantly: it is free within the first 2 minutes after driver assignment; after that, a \$5.00 cancellation fee applies.';
  String get sendCancellationRequest =>
      _es ? 'Cancelar viaje ahora' : 'Cancel trip now';
  String get cancelRequestSentToSupport => _es
      ? 'Viaje cancelado.'
      : 'Trip cancelled.';
  // ── Chat ──────────────────────────────────────────────────────────────────
  String get connectionIssueRetrying => _es
      ? 'Problema de conexión - reintentando...'
      : 'Connection issue - retrying...';
  String get retryLabel => _es ? 'Reintentar' : 'Retry';

  // ── Trip Receipt ──────────────────────────────────────────────────────────
  String get couldNotSendReceipt => _es
      ? 'No se pudo enviar el recibo. Intenta más tarde.'
      : 'Could not send receipt. Try again later.';
  String get distance => _es ? 'Distancia' : 'Distance';
  String get duration => _es ? 'Duración' : 'Duration';
  String get completed => _es ? 'Completado' : 'Completed';

  // ── Ride Rating ────────────────────────────────────────────────────────────
  String get submitRating => _es ? 'Enviar Calificación' : 'Submit Rating';
  String submitWithTip(String amount) =>
      _es ? 'Enviar · propina \$$amount' : 'Submit · \$$amount tip';
  String get ratingPoor => _es ? 'Malo' : 'Poor';
  String get ratingBelowAverage =>
      _es ? 'Por Debajo del Promedio' : 'Below Average';
  String get ratingAverage => _es ? 'Regular' : 'Average';
  String get ratingGreat => _es ? 'Genial' : 'Great';
  String get ratingExcellent => _es ? '¡Excelente!' : 'Excellent!';

  // ── Driver Menu ────────────────────────────────────────────────────────────
  String get menuTitle => _es ? 'Menú' : 'Menu';
  String get opportunities => _es ? 'Oportunidades' : 'Opportunities';
  String get findMoreEarnings =>
      _es ? 'Encuentra más ganancias' : 'Find more earnings';
  String get cruiseLevelLabel => _es ? 'Nivel Cruise' : 'Cruise Level';
  String get workHub => _es ? 'Centro de Trabajo' : 'Work Hub';
  String get deliveryAndServices =>
      _es ? 'Entrega y servicios' : 'Delivery & services';
  String get referFriends => _es ? 'Referir Amigos' : 'Refer Friends';
  String get earnBonuses => _es ? 'Gana bonificaciones' : 'Earn bonuses';
  String get scheduledTripsMenu =>
      _es ? 'Viajes Programados' : 'Scheduled Trips';
  String get upcomingRides =>
      _es ? 'Viajes asignados próximos' : 'Upcoming assigned rides';
  String get vehiclesLabel => _es ? 'Vehículos' : 'Vehicles';
  String get yourCarDetails => _es ? 'Detalles de tu auto' : 'Your car details';
  String get documentsLabel => _es ? 'Documentos' : 'Documents';
  String get licenseAndInsurance =>
      _es ? 'Licencia y seguro' : 'License & insurance';
  String get insuranceLabel => _es ? 'Seguro' : 'Insurance';
  String get coverageInfo => _es ? 'Información de cobertura' : 'Coverage info';
  String get taxInfo => _es ? 'Info de Impuestos' : 'Tax Info';
  String get taxDocsAndForms =>
      _es ? 'Documentos e impuestos' : 'Tax documents & forms';
  String get payoutMethodsLabel => _es ? 'Métodos de pago' : 'Payout methods';
  String get bankAndPaymentSetup =>
      _es ? 'Configuración bancaria' : 'Bank & payment setup';
  String get plusCard => _es ? 'Tarjeta Plus' : 'Plus Card';
  String get cruiseDebitCard =>
      _es ? 'Tarjeta de débito Cruise' : 'Cruise debit card';
  String get learningCenter =>
      _es ? 'Centro de Aprendizaje' : 'Learning Center';
  String get tipsAndGuides => _es ? 'Consejos y guías' : 'Tips & guides';
  String get bugReporter => _es ? 'Reportar Error' : 'Bug Reporter';
  String get reportIssues => _es ? 'Reportar problemas' : 'Report issues';
  String get signOut => _es ? 'Cerrar sesión' : 'Sign out';
  String get logOutAccount =>
      _es ? 'Cerrar sesión de tu cuenta' : 'Log out of your account';
  String get moreWaysToEarn =>
      _es ? 'Más formas de ganar' : 'More ways to earn';
  String get manageSectionLabel => _es ? 'Administrar' : 'Manage';
  String get moneySectionLabel => _es ? 'Dinero' : 'Money';
  String get resourcesSectionLabel => _es ? 'Recursos' : 'Resources';
  String get helpLabel => _es ? 'Ayuda' : 'Help';
  String get safetyLabel => _es ? 'Seguridad' : 'Safety';
  String get aboutLabel => _es ? 'Acerca de' : 'About';

  // ── Driver Settings ────────────────────────────────────────────────────────
  String get settingsTitle => _es ? 'Configuración' : 'Settings';
  String get editAccountDetails =>
      _es ? 'Editar detalles de tu cuenta' : 'Edit your account details';
  String get dataPrivacySettings =>
      _es ? 'Configuración de privacidad' : 'Data & privacy settings';
  String get editAddress => _es ? 'Editar Dirección' : 'Edit Address';
  String get homeWorkAddresses =>
      _es ? 'Direcciones de casa y trabajo' : 'Home & work addresses';
  String get generalLabel => _es ? 'General' : 'General';
  String get accessibilityLabel => _es ? 'Accesibilidad' : 'Accessibility';
  String get accessibilityFeatures =>
      _es ? 'Funciones de accesibilidad' : 'Accessibility features';

  // Accessibility screen strings
  String get textSize => _es ? 'Tamaño del texto' : 'Text Size';
  String get textSizePreview =>
      _es ? 'Vista previa del texto' : 'Text size preview';
  String get highContrast => _es ? 'Alto contraste' : 'High Contrast';
  String get highContrastDesc =>
      _es ? 'Aumentar contraste de colores' : 'Increase color contrast';
  String get reduceMotion => _es ? 'Reducir movimiento' : 'Reduce Motion';
  String get reduceMotionDesc =>
      _es ? 'Minimizar animaciones' : 'Minimize animations';
  String get screenReaderHints =>
      _es ? 'Pistas para lector de pantalla' : 'Screen Reader Hints';
  String get screenReaderHintsDesc => _es
      ? 'Descripciones adicionales para accesibilidad'
      : 'Extra descriptions for accessibility';
  String get colorBlindMode => _es ? 'Modo daltónico' : 'Color Blind Mode';
  String get colorBlindNone => _es ? 'Ninguno' : 'None';
  String get colorBlindProtanopia =>
      _es ? 'Protanopia (rojo-verde)' : 'Protanopia (red-green)';
  String get colorBlindDeuteranopia =>
      _es ? 'Deuteranopia (verde-rojo)' : 'Deuteranopia (green-red)';
  String get colorBlindTritanopia =>
      _es ? 'Tritanopia (azul-amarillo)' : 'Tritanopia (blue-yellow)';
  String get hapticFeedback => _es ? 'Vibración háptica' : 'Haptic Feedback';
  String get hapticFeedbackDesc =>
      _es ? 'Vibraciones para acciones' : 'Vibrations for actions';

  String get appAppearance => _es ? 'Apariencia de la app' : 'App appearance';
  String get siriShortcuts =>
      _es ? 'Accesos directos de Siri' : 'Siri Shortcuts';
  String get voiceCommands => _es ? 'Comandos de voz' : 'Voice commands';
  String get communicationLabel => _es ? 'Comunicación' : 'Communication';
  String get messagePreferences =>
      _es ? 'Preferencias de mensajes' : 'Message preferences';
  String get navigationLabel => _es ? 'Navegación' : 'Navigation';
  String get mapsRoutingPrefs =>
      _es ? 'Preferencias de mapas y rutas' : 'Maps & routing preferences';
  String get soundsAndVoice => _es ? 'Sonidos y Voz' : 'Sounds & Voice';
  String get audioVoiceSettings =>
      _es ? 'Configuración de audio y voz' : 'Audio & voice settings';

  // ── Driver Earnings ────────────────────────────────────────────────────────
  String get earningsTitle => _es ? 'Ganancias' : 'Earnings';
  String get cashOut => _es ? 'Retirar' : 'Cash Out';
  String get thisWeek => _es ? 'Esta Semana' : 'This Week';
  String get thisMonth => _es ? 'Este Mes' : 'This Month';

  // ── Cruise Level, rebuilt layout ──
  String get cruiseAverageRating =>
      _es ? 'Calificación media' : 'Average rating';
  String get cruisePerformanceMetrics => _es ? 'RENDIMIENTO' : 'PERFORMANCE';
  String cruiseYourRewards(String tier) =>
      _es ? 'Tus recompensas $tier' : 'Your $tier rewards';
  String get cruiseEarnMore => _es ? 'Gana más' : 'Get more earnings';
  String get cruiseKeepDriving => _es
      ? 'Sigue conduciendo para desbloquearlo'
      : 'Keep driving to unlock it';
  String cruiseUnlock(String tier) =>
      _es ? 'Desbloquear $tier' : 'Unlock $tier';
  String cruiseFocusOn(int remaining, int total) => _es
      ? 'Te faltan $remaining de $total requisitos'
      : 'Focus on $remaining of $total requirements';
  String get cruiseAllRequirementsMet =>
      _es ? 'Cumples todos los requisitos' : 'You meet every requirement';
  String cruiseGoal(String goal) => _es ? 'Meta: $goal' : 'Goal: $goal';
  String get cruiseGoalMet => _es ? 'Cumplido' : 'Met';
  String get cruiseFocusArea => _es ? 'A mejorar' : 'Focus area';
  String get cruiseAllTime => _es ? 'Desde que empezaste' : 'Since you started';

  // ── How Cruise Level works ──
  // Every claim below is checked against cruise_level_agent.compute_tier(),
  // which reads completed trips and the average rating and nothing else.
  String get cruiseLearnMore => _es ? 'Saber más' : 'Learn more';
  String get cruiseHowItWorks =>
      _es ? 'Cómo funciona Cruise Level' : 'How Cruise Level Works';
  String get cruiseWhatIsRequired => _es
      ? '¿Qué se necesita para cada nivel?'
      : "What's required for each level?";
  String get cruiseCriteriaIntro => _es
      ? 'Tu nivel depende de dos cosas: cuántos viajes has completado y tu '
          'calificación media. Necesitas cumplir las dos para llegar a un '
          'nivel.'
      : 'Your level comes down to two things: how many trips you have '
          'completed and your average rating. You need to meet both to reach '
          'a level.';
  String get cruiseLevelColumn => _es ? 'NIVEL' : 'LEVEL';
  String get cruiseYouColumn => _es ? 'Tú' : 'You';
  // Short enough to fit their columns at 11.5px — the full names ellipsize.
  String get cruiseTripsColumn => _es ? 'VIAJES' : 'TRIPS';
  String get cruiseRatingColumn => _es ? 'CALIF.' : 'RATING';
  String get cruiseStartHere => _es ? 'Inicio' : 'Start';
  String get cruiseHowYouMoveUp => _es ? 'Cómo subes' : 'How you move up';
  String get cruiseHowYouMoveUpBody => _es
      ? 'Los viajes se acumulan desde tu primer día y no se reinician a fin '
          'de mes. Revisamos tu nivel cada vez que terminas un viaje y cada '
          'vez que un pasajero te califica, así que subes en cuanto cumples '
          'los dos requisitos: no hay que esperar a nada.'
      : 'Trips add up from your first day and do not reset at the end of the '
          'month. We check your level every time you finish a trip and every '
          'time a rider rates you, so you move up as soon as you meet both '
          'requirements — there is nothing to wait for.';
  String get cruiseAboutTheRates =>
      _es ? 'Sobre las tasas de rendimiento' : 'About the performance rates';
  String get cruiseAboutTheRatesBody => _es
      ? 'Tu tasa de aceptación, cancelación, satisfacción y puntualidad son '
          'informativas: te muestran cómo vas, pero no cuentan para tu nivel '
          'ni para tu calificación. Lo único que decide tu nivel son los '
          'viajes completados y las estrellas que te dejan los pasajeros.'
      : 'Your acceptance, cancellation, satisfaction and on-time rates are '
          'there for information: they show you how you are doing, but they '
          'count toward neither your level nor your rating. The only things '
          'that decide your level are completed trips and the stars riders '
          'leave you.';

  String get cruiseKeepingYourLevel =>
      _es ? 'Cómo conservas tu nivel' : 'Keeping your level';
  String get cruiseKeepingYourLevelBody => _es
      ? 'Los viajes completados nunca bajan, pero tu calificación sí puede '
          'bajar. Si cae por debajo del mínimo de tu nivel, bajas un nivel y '
          'te avisamos. Vuelves a subir en cuanto tu calificación se '
          'recupera.'
      : 'Completed trips never go down, but your rating can. If it falls '
          'below your level\'s minimum you drop a level, and we let you know. '
          'You go back up as soon as your rating recovers.';

  // ── Payout methods, rebuilt layout ──
  String get payoutYourMethods =>
      _es ? 'Tus métodos de cobro' : 'Your payout methods';
  // Monday, because that is when the scheduler actually fires — see
  // _PAYOUT_WEEKDAY = 0 in backend/main.py. This line has said Tuesday and
  // Wednesday at different times; neither was ever the run day.
  String get payoutMethodsIntro => _es
      ? 'Tus ganancias se depositan cada lunes, salvo que pidas retirarlas '
          'antes a tu tarjeta de débito.'
      : 'Your earnings are deposited every Monday, unless you ask to cash '
          'out sooner to your debit card.';
  String get payoutExpressPay => _es ? 'Retiro exprés' : 'Express Pay';
  String get payoutWeekly => _es ? 'Pago semanal' : 'Weekly payouts';
  String get payoutOnRequest => _es ? 'A petición' : 'On request';
  String get payoutActive => _es ? 'Activo' : 'Active';
  String get payoutSetUp => _es ? 'Configurar' : 'Set up';
  String get payoutExpressPayDesc => _es
      ? 'Cobra cuando quieras, con una comisión'
      : 'Cash out whenever you like, for a fee';
  String get payoutWeeklyDesc =>
      _es ? 'Cada lunes, sin comisión' : 'Every Monday, no fee';
  String payoutEndingIn(String last4) =>
      _es ? 'Terminada en •$last4' : 'Ending in •$last4';

  String get payoutUpdateCard =>
      _es ? 'Actualizar tarjeta' : 'Update debit card';
  // "Retiro instantáneo" / "Instant cashout", matching the card that opens
  // this sheet. It said "Retiro exprés" / "Express Pay", a product name
  // nothing else in the app shows any more.
  String get payoutUpdateCardDesc => _es
      ? 'Con el Retiro instantáneo puedes cobrar tus ganancias cuando '
          'quieras, con una pequeña comisión cada vez.'
      : 'With Instant cashout you can cash out your earnings whenever you '
          'want, for a small fee each time.';
  String get payoutKeepSecure =>
      _es ? 'Protege tus ganancias' : 'Keep your earnings secure';
  String get payoutKeepSecureCard => _es
      ? 'Nunca pongas la tarjeta de otra persona para tus ganancias. '
          'Cruise jamás te pedirá que añadas una tarjeta concreta.'
      : "Never enter someone else's card for your earnings. Cruise will "
          'never ask you to add a specific card.';
  // ── Payout methods, card layout ──
  //
  // One card per way of getting paid, each answering the same three
  // questions in the same order: what it costs, when it lands, and where.
  String get payoutAvailableSection => _es ? 'Disponibles' : 'Available';
  String get payoutFeeFree => _es ? 'Sin comisión' : 'Free';
  String payoutFeePercent(String rate, String min) => _es
      ? '$rate de comisión (mín. $min)'
      : '$rate fee (min $min)';
  String get payoutWhenWeekly => _es
      ? 'Cada lunes · llega en 1–2 días hábiles'
      : 'Every Monday · arrives in 1–2 business days';
  String get payoutWhenInstant => _es
      ? 'Cuando quieras · llega en minutos'
      : 'Whenever you want · arrives in minutes';
  String get payoutNoBankLinked =>
      _es ? 'Sin cuenta vinculada' : 'No account linked';
  String get payoutNoCardLinked =>
      _es ? 'Sin tarjeta vinculada' : 'No card linked';
  String get payoutAddBank =>
      _es ? 'Agregar cuenta bancaria' : 'Add a bank account';
  String get payoutAddCard =>
      _es ? 'Agregar tarjeta de débito' : 'Add a debit card';
  String get payoutChangeBank => _es ? 'Cambiar cuenta' : 'Change account';
  String get payoutChangeCard => _es ? 'Cambiar tarjeta' : 'Change card';
  String payoutInstantMinimum(String amount) =>
      _es ? 'Mínimo $amount por retiro' : 'Minimum $amount per cashout';
  String get payoutHelpTitle =>
      _es ? '¿Cómo te pagamos?' : 'How you get paid';
  String get payoutHelpWeekly => _es
      ? 'Cada lunes enviamos tus ganancias a tu cuenta bancaria, sin '
          'comisión. Suelen llegar en uno o dos días hábiles.'
      : 'Every Monday we send your earnings to your bank account, with no '
          'fee. They usually arrive within one or two business days.';
  // ── Cash out screen ──
  //
  // One page, one action. The balance, the day it empties on its own, and
  // the button that empties it sooner.
  String get cashoutAvailableBalance =>
      _es ? 'Saldo disponible' : 'Available balance';
  String cashoutAutoTransferOn(String date) => _es
      ? 'La transferencia semanal se hará el $date'
      : 'Weekly auto-transfer will initiate on $date';
  String get cashoutInstantButton =>
      _es ? 'Retiro instantáneo' : 'Instant Cash out';
  String cashoutFeeLine(String fee, String net) => _es
      ? 'Comisión $fee · recibes $net'
      : 'Fee $fee · you receive $net';
  String get cashoutProcessing =>
      _es ? 'Procesando tu retiro…' : 'Processing your cash out…';
  String get cashoutProcessingHint => _es
      ? 'No cierres la app. Esto toma unos segundos.'
      : 'Keep the app open. This takes a few seconds.';
  String cashoutBelowMinimum(String amount) => _es
      ? 'Necesitas al menos $amount para retirar'
      : 'You need at least $amount to cash out';
  String get cashoutNeedCard => _es
      ? 'Agrega una tarjeta de débito para retirar al instante'
      : 'Add a debit card to cash out instantly';
  String get cashoutAddCardAction =>
      _es ? 'Agregar tarjeta' : 'Add a card';
  // Seven days is Stripe's verification window on a newly attached card,
  // not a waiting period we invented — say so, or it reads as us holding
  // the driver's money back.
  String cashoutCardVerifying(int days) => _es
      ? days == 1
          ? 'Tu tarjeta está en verificación. Podrás retirar mañana.'
          : 'Tu tarjeta está en verificación. Podrás retirar en $days días.'
      : days == 1
          ? 'Your card is being verified. You can cash out tomorrow.'
          : 'Your card is being verified. You can cash out in $days days.';
  String get cashoutComingSoon => _es
      ? 'El retiro instantáneo estará disponible muy pronto'
      : 'Instant Cash out is coming soon';
  String get cashoutUnavailable => _es
      ? 'El retiro instantáneo no está disponible ahora mismo'
      : 'Instant Cash out is not available right now';
  String get cashoutNothingToWithdraw =>
      _es ? 'No tienes saldo para retirar' : 'You have nothing to cash out';
  String get cashoutFailed => _es
      ? 'No pudimos completar el retiro. Intenta de nuevo o escribe a soporte.'
      : 'We could not complete the cash out. Try again or contact support.';
  String get cashoutInsufficient =>
      _es ? 'Saldo insuficiente.' : 'Insufficient balance.';
  String get cashoutNoStripeAccount => _es
      ? 'Todavía no puedes cobrar: termina de configurar tus pagos en '
          'Métodos de pago.'
      : 'You cannot be paid yet — finish setting up your payouts in Payout '
          'methods.';
  // Stripe said no before any money moved. Saying so is the whole point:
  // the balance on screen did not change and the driver should not spend
  // the next minute wondering whether it did.
  String get cashoutNotStarted => _es
      ? 'No pudimos iniciar el retiro. Tu saldo está intacto, inténtalo de '
          'nuevo.'
      : 'We could not start the cash out. Your balance is untouched — please '
          'try again.';
  // The request timed out. It may well have gone through, and telling them
  // it failed would be a guess — one they can check for themselves.
  String get cashoutUncertain => _es
      ? 'Tardó más de lo normal. Puede que sí haya salido: revisa el '
          'historial en un minuto antes de intentar otra vez.'
      : 'That took longer than usual. It may still have gone through — check '
          'your payout history in a minute before trying again.';
  // The instant leg failed but the money already left the platform, so it
  // lands on the normal weekly schedule instead. Not an error — a slower
  // arrival, and the driver has to be told which one happened.
  String get cashoutQueuedInstead => _es
      ? 'Tu retiro se envió, pero no pudo salir al instante. Llegará a tu '
          'cuenta en 1–2 días hábiles.'
      : 'Your cash out was sent, but it could not go out instantly. It will '
          'reach your account in 1–2 business days.';

  // ── Cash out history ──
  //
  // Two groups, split by whether the money has landed. Every row names
  // which of the two ways it moved, because an instant cashout the driver
  // asked for and the Monday transfer that happens on its own otherwise
  // look identical: a date and an amount.
  String get cashoutInitiatedBy =>
      _es ? 'Iniciado por Cruise' : 'Initiated by Cruise';
  String get cashoutInitiatedNote => _es
      ? 'Tu pago se depositará en tu cuenta en 2–3 días hábiles.'
      : 'Your payment will deposit to your bank in 2–3 business days.';
  // "Enviado", not "Depositado en el banco".
  //
  // A row reaches this section the moment Stripe accepts the transfer, which
  // for the Monday run is about two business days before the money is in
  // anyone's bank. Calling that "deposited" sends drivers to check an
  // account that has nothing in it yet. The note below carries the two real
  // arrival times, because they differ by method and a section heading
  // cannot say both.
  String get cashoutDeposited => _es ? 'Enviado' : 'Sent';
  String get cashoutDepositedNote => _es
      ? 'Los depósitos semanales tardan 2–3 días hábiles en llegar a tu '
          'banco. Los retiros instantáneos llegan a tu tarjeta en minutos.'
      : 'Weekly deposits take 2–3 business days to reach your bank. Instant '
          'cashouts reach your card in minutes.';
  String get cashoutRowInstant =>
      _es ? 'Retiro instantáneo' : 'Instant cashout';
  String get cashoutRowWeekly =>
      _es ? 'Depósito semanal' : 'Weekly deposit';
  String get cashoutHistoryEmpty => _es
      ? 'Todavía no has recibido ningún pago.'
      : 'You have not been paid yet.';
  String get cashoutHistoryUnavailable => _es
      ? 'No pudimos cargar tu historial de pagos.'
      : 'We could not load your payout history.';
  String get cashoutDetailTitle => _es ? 'Detalle del pago' : 'Payment detail';
  String get cashoutDetailGross => _es ? 'Monto' : 'Amount';
  String get cashoutDetailFee => _es ? 'Comisión' : 'Fee';
  String get cashoutDetailNet => _es ? 'Recibiste' : 'You received';
  String get cashoutDetailMethod => _es ? 'Método' : 'Method';
  String get cashoutDetailStatus => _es ? 'Estado' : 'Status';
  String get cashoutDetailDate => _es ? 'Fecha' : 'Date';
  // "Enviado", for the same reason the section is: Stripe accepting the
  // transfer is not the money being in a bank account.
  String get cashoutStatusCompleted => _es ? 'Enviado' : 'Sent';
  String get cashoutStatusProcessing =>
      _es ? 'En camino' : 'On its way';

  String get payoutHelpInstant => _es
      ? 'Si no quieres esperar al lunes, retira cuando quieras a tu tarjeta '
          'de débito. La comisión es de 1.5% (mínimo \$0.50) y el retiro '
          'mínimo es de \$50.'
      : 'If you would rather not wait for Monday, cash out to your debit '
          'card whenever you want. The fee is 1.5% (minimum \$0.50) and the '
          'smallest cashout is \$50.';

  // ── Earnings screen, rebuilt layout ──
  String get earningsPeriodDay => _es ? 'Hoy' : 'Today';
  String get earningsPeriodWeek => _es ? 'Semana' : 'Week';
  String get earningsPeriodMonth => _es ? 'Mes' : 'Month';
  String get earningsPeriodYear => _es ? 'Año' : 'Year';
  String get earningsNoneYet =>
      _es ? 'Aún no hay ganancias' : 'No earnings yet';
  String get earningsYourStats => _es ? 'Tus estadísticas' : 'Your stats';
  String get earningsActions => _es ? 'Acciones' : 'Actions';
  String get earningsStatsCard => _es ? 'Ganancias' : 'Earnings';
  String get earningsPerOnlineHour =>
      _es ? 'por hora en línea' : 'per online hour';
  String get earningsExcludingTips => _es ? 'sin propinas' : 'excluding tips';
  String get earningsDrivingCard => _es ? 'Conducción' : 'Driving';
  String get earningsRidesCompleted =>
      _es ? 'Viajes completados' : 'Rides completed';
  String get earningsRidesRejected =>
      _es ? 'Viajes rechazados' : 'Rides rejected';
  String get earningsTipsCard => _es ? 'Propinas' : 'Tips';
  String earningsFromTrips(int n) => _es ? 'de $n viajes' : 'from $n trips';
  String get earningsHideMine =>
      _es ? 'Ocultar mis ganancias' : 'Hide my earnings';
  String get earningsHideMineDesc => _es
      ? 'Tapa el importe del mapa; deja solo el \$'
      : 'Covers the amount on the map, leaving just the \$';
  String get earningsPayoutHistory =>
      _es ? 'Historial de pagos' : 'Payout history';
  String get earningsPayoutMethods =>
      _es ? 'Métodos de cobro' : 'Payout methods';
  String get earningsPayoutMethodsDesc =>
      _es ? 'Dónde recibes tu dinero' : 'Where your money arrives';
  String get earningsAvailable => _es ? 'disponible' : 'available';

  /// Hours and minutes, never a decimal — "5.5h" is not a time.
  String earningsOnlineTime(int hours, int minutes) {
    if (hours == 0) return _es ? '$minutes min' : '${minutes}min';
    if (minutes == 0) return '${hours}h';
    return _es ? '${hours}h $minutes min' : '${hours}h ${minutes}min';
  }

  String availableBalance(String amount) =>
      _es ? 'Saldo disponible: \$$amount' : 'Available balance: \$$amount';
  String get fundsTransferDesc => _es
      ? 'Los fondos se transferirán a tu banco en 1-3 días hábiles.'
      : 'Funds will be transferred to your bank within 1-3 business days.';
  String cashOutInitiated(String amount) => _es
      ? '¡Retiro de \$$amount iniciado!'
      : 'Cash out of \$$amount initiated!';
  String cashOutFailed(String e) =>
      _es ? 'Error al retirar: $e' : 'Cash out failed: $e';
  String get confirmCashOut => _es ? 'Confirmar Retiro' : 'Confirm Cash Out';

  // ── Driver Trip History ────────────────────────────────────────────────────
  String get tripHistoryTitle => _es ? 'Historial de Viajes' : 'Trip History';
  String get allFilter => _es ? 'Todos' : 'All';
  String get completedFilter => _es ? 'Completados' : 'Completed';
  String get cancelledFilter => _es ? 'Cancelados' : 'Cancelled';
  String get noTripsFound =>
      _es ? 'No se encontraron viajes' : 'No trips found';
  String get noCompletedTrips =>
      _es ? 'No hay viajes completados' : 'No completed trips yet';
  String get noCancelledTrips =>
      _es ? 'No hay viajes cancelados' : 'No cancelled trips';

  // ── Driver Pending Review ──────────────────────────────────────────────────
  String get applicationUnderReview =>
      _es ? 'Solicitud en Revisión' : 'Application Under Review';
  String get reviewDescription => _es
      ? 'Nuestro equipo de despacho está revisando tu solicitud y documentos. Esto normalmente tarda 24–48 horas.'
      : 'Our dispatch team is reviewing your application and documents. This typically takes 24–48 hours.';
  String get applicationSubmitted =>
      _es ? 'Solicitud enviada' : 'Application submitted';
  String get allDocsReceived =>
      _es ? 'Todos los documentos recibidos' : 'All documents received';
  String get backgroundCheck =>
      _es ? 'Verificación de antecedentes' : 'Background check';
  String get identityDocsVerified => _es
      ? 'Documentos de identidad verificados'
      : 'Identity documents verified';
  String get finalReview => _es ? 'Revisión final' : 'Final review';
  String get dispatchApprovalPending =>
      _es ? 'Aprobación de despacho pendiente' : 'Dispatch approval pending';
  String get checkingForUpdates =>
      _es ? 'Verificando actualizaciones...' : 'Checking for updates...';
  String get youreApproved => _es ? '¡Estás Aprobado!' : "You're Approved!";
  String get welcomeDriverTeam => _es
      ? 'Bienvenido al equipo de conductores de Cruise. Ya puedes conectarte y empezar a aceptar viajes.'
      : 'Welcome to the Cruise driver team. You can now go online and start accepting rides.';

  // ── Notifications Screen ───────────────────────────────────────────────────
  String get helpUsKeepInformed =>
      _es ? 'Ayúdanos a mantenerte informado' : 'Help us keep you\ninformed';
  String get allowNotifsDescription => _es
      ? 'Permite notificaciones para recibir actualizaciones de viajes en tiempo real e información útil sobre tu cuenta'
      : 'Allow notifications to get real-time ride\nupdates and helpful information about your\naccount';
  String get allowBtn => _es ? 'Permitir' : 'Allow';

  // ── Scheduled Rides ────────────────────────────────────────────────────────
  String get noScheduledRides =>
      _es ? 'Sin Viajes Programados' : 'No Scheduled Rides';
  String get scheduleFromHome => _es
      ? 'Programa un viaje desde la pantalla principal\ny aparecerá aquí'
      : 'Schedule a ride from the home screen\nand it will appear here';
  String get scheduleARide => _es ? 'Programar un Viaje' : 'Schedule a Ride';
  String get cancelRideBtn => _es ? 'Cancelar Viaje' : 'Cancel Ride';
  String failedToCancel(String e) =>
      _es ? 'Error al cancelar: $e' : 'Failed to cancel: $e';

  // ── Chat Screen ────────────────────────────────────────────────────────────
  String get cruiseSupport => _es ? 'Soporte Cruise' : 'Cruise Support';
  String get online => _es ? 'En línea' : 'Online';
  String get activeNow => _es ? 'Activo ahora' : 'Active now';
  String get chatWelcome => _es
      ? '¡Hola! ¿Cómo podemos ayudarte hoy?'
      : 'Hi! How can we help you today?';
  String get describeIssue =>
      _es ? 'Describe tu problema...' : 'Describe your issue...';
  String get typing => _es ? 'escribiendo...' : 'typing...';

  // ── Inbox Screen ───────────────────────────────────────────────────────────
  String get welcomeToCruise =>
      _es ? '¡Bienvenido a Cruise!' : 'Welcome to Cruise!';
  String get welcomePromo => _es
      ? 'Disfruta 15% de descuento en tus primeros 3 viajes. Usa el código CRUISE15.'
      : 'Enjoy 15% off your first 3 rides. Use code CRUISE15.';
  String get justNow => _es ? 'Ahora mismo' : 'Just now';
  String get noNotifications => _es ? 'Sin notificaciones' : 'No notifications';
  String get allCaughtUp => _es ? '¡Estás al día!' : "You're all caught up!";
  String get markAllRead => _es ? 'Marcar todo como leído' : 'Mark all read';
  String get noMessagesYet => _es ? 'Aún no hay mensajes' : 'No messages yet';
  String get messagesWillAppear => _es
      ? 'Los mensajes de tus conductores y el soporte de Cruise aparecerán aquí.'
      : 'Messages from your drivers and Cruise support will appear here.';

  // ── Map Picker Screen ──────────────────────────────────────────────────────
  String get moveMapToPickLocation => _es
      ? 'Mueve el mapa para elegir una ubicación'
      : 'Move the map to pick a location';
  String get findingAddress =>
      _es ? 'Buscando dirección...' : 'Finding address...';
  String get confirmLocation =>
      _es ? 'Confirmar ubicación' : 'Confirm Location';
  String get confirmPickupLocation =>
      _es ? 'Confirmar punto de recogida' : 'Confirm Pickup Location';
  String get confirmDropoffLocation =>
      _es ? 'Confirmar destino' : 'Confirm Dropoff Location';
  String get setPickupOnMap => _es
      ? 'Mueve el mapa para elegir recogida'
      : 'Move map to set pickup location';
  String get setDropoffOnMap => _es
      ? 'Mueve el mapa para elegir destino'
      : 'Move map to set dropoff location';

  // ── Payment Method Screen ──────────────────────────────────────────────────
  String get howWouldYouLikeToPay =>
      _es ? '¿Cómo deseas\npagar?' : 'How would you like\nto pay?';
  String get chargedAfterRide => _es
      ? 'Solo se te cobrará después del viaje.'
      : "You'll only be charged after the ride.";
  String get paymentRetryInfo => _es
      ? 'Si hay algún problema con tu pago, reintentaremos con otros métodos de respaldo en tu cuenta.'
      : "If there's ever a problem with your payment, we'll retry with other backup payment methods in your account so you can continue using Cruise.";
  String get setUpLater => _es ? 'Configurar después' : 'Set up later';
  String get confirmGooglePay =>
      _es ? 'Confirmar Google Pay' : 'Confirm Google Pay';
  String get googlePayPrompt => _es
      ? 'Toca el botón de abajo para confirmar Google Pay para los viajes de Cruise.'
      : 'Tap the button below to confirm Google Pay for Cruise rides.';
  String get accountVerification =>
      _es ? 'Verificación de cuenta' : 'Account verification';
  String get googlePayLinked => _es
      ? 'Google Pay vinculado exitosamente'
      : 'Google Pay linked successfully';
  String get applePayLinked => _es
      ? 'Apple Pay vinculado exitosamente'
      : 'Apple Pay linked successfully';
  String get googlePayNotSetUp => _es
      ? 'Google Pay no está configurado en este dispositivo'
      : 'Google Pay not set up on this device';
  String get applePayNotSetUp => _es
      ? 'Apple Pay no está configurado en este dispositivo'
      : 'Apple Pay not set up on this device';
  String get cruiseCashActivated =>
      _es ? 'Cruise Cash activado' : 'Cruise Cash activated';
  String get paypalLinked =>
      _es ? 'PayPal vinculado exitosamente' : 'PayPal linked successfully';

  // ── Promo Code Screen ──────────────────────────────────────────────────────
  String get promotions => _es ? 'Promociones' : 'Promotions';
  String get havePromoCode =>
      _es ? '¿Tienes un código de promoción?' : 'Have a promo code?';
  String get enterCode => _es ? 'Ingresar código' : 'Enter code';
  String get availablePromos => _es ? 'Promos disponibles' : 'Available Promos';
  String get noPromosAvailable =>
      _es ? 'No hay promos disponibles' : 'No promos available';
  String get couldNotValidatePromo => _es
      ? 'No se pudo validar el código de promo'
      : 'Could not validate promo code';
  String get used => _es ? 'Usado' : 'Used';
  String get expired => _es ? 'Vencido' : 'Expired';
  String expiresInDays(int days) => _es
      ? 'Vence en $days ${days == 1 ? 'día' : 'días'}'
      : 'Expires in $days day${days == 1 ? '' : 's'}';

  // ── Account Deactivated Screen ─────────────────────────────────────────────
  String get accountDeactivatedMsg => _es
      ? 'Tu cuenta ha sido desactivada. Por favor contacta soporte para más información.'
      : 'Your account has been deactivated. Please contact support for more information.';

  // ── Terms & Conditions Screen ──────────────────────────────────────────────
  String get termsAndConditions =>
      _es ? 'Términos y Condiciones' : 'Terms & Conditions';

  // ── Driver Inbox Screen ────────────────────────────────────────────────────
  String get alertsTab => _es ? 'Alertas' : 'Alerts';
  String get updatesTab => _es ? 'Actualizaciones' : 'Updates';
  String get dealsTab => _es ? 'Ofertas' : 'Deals';
  String get noMessages => _es ? 'Sin mensajes' : 'No messages';

  // ── Driver Profile Photo Screen ────────────────────────────────────────────
  String get uploadProfilePhoto =>
      _es ? 'Subir Foto de Perfil' : 'Upload Profile Photo';
  String get profilePhotoInstructions => _es
      ? 'Los pasajeros verán esta foto cuando aceptes su viaje. Asegúrate de que sea una foto clara de tu rostro.'
      : "Riders will see this photo when you accept their trip. Make sure it's a clear photo of your face.";
  String get tapToAdd => _es ? 'Toca para agregar' : 'Tap to add';
  String uploadFailed(String e) =>
      _es ? 'Error al subir: $e' : 'Upload failed: $e';

  // ── Driver Documents Screen ────────────────────────────────────────────────
  String get documentsTitle => _es ? 'Documentos' : 'Documents';
  String get documentStatus => _es ? 'Estado de documentos' : 'Document Status';
  String docsApproved(int approved, int total) => _es
      ? '$approved de $total documentos aprobados'
      : '$approved of $total documents approved';
  String get uploadNewDocument =>
      _es ? 'Subir nuevo documento' : 'Upload New Document';
  String get primaryVehicle => _es ? 'Vehículo principal' : 'Primary Vehicle';
  String get viewIssue => _es ? 'VER PROBLEMA' : 'VIEW ISSUE';
  String get licensePlateNumber =>
      _es ? 'Número de placa' : 'License Plate Number';
  String get licensePlateIntro => _es
      ? 'Ingresa el número de placa de tu vehículo para seguir recibiendo viajes.'
      : 'Please provide your license plate number in order to continue '
          'receiving rides.';
  String get confirmLicensePlate =>
      _es ? 'Confirmar número de placa' : 'Confirm license plate number';
  String get stateLabel => _es ? 'Estado' : 'State';
  String get platesDoNotMatch => _es
      ? 'Los dos números de placa no coinciden'
      : 'The two plate numbers do not match';
  String get plateChangeWarning => _es
      ? 'Si cambias la placa tendrás que subir la registración otra vez y '
          'esperar la aprobación. No podrás ponerte en línea mientras tanto.'
      : 'Changing your plate means uploading your registration again and '
          'waiting for approval. You will not be able to go online until then.';
  String get plateSaved => _es ? 'Placa actualizada' : 'License plate updated';
  String get plateChangePendingTitle => _es
      ? 'Esperando aprobación de la placa'
      : 'Plate change under review';
  String get plateChangePendingBody => _es
      ? 'Cambiaste la placa. Sube la registración nueva y espera a que la '
          'aprueben para volver a estar en línea.'
      : 'You changed your plate. Upload the new registration and wait for it '
          'to be approved before going online again.';
  String get docsActionNeeded => _es ? 'Falta por hacer' : 'Action needed';
  String get docsSubmitted => _es ? 'Entregados' : 'Completed';
  String docsItemCount(int n) =>
      _es ? (n == 1 ? '1 punto' : '$n puntos') : (n == 1 ? '1 item' : '$n items');
  String get approved => _es ? 'Aprobado' : 'Approved';
  String get pending => _es ? 'Pendiente' : 'Pending';
  String get uploadBtn => _es ? 'Subir' : 'Upload';
  String get rejected => _es ? 'Rechazado' : 'Rejected';
  String get notUploadedYet => _es ? 'Aún no subido' : 'Not uploaded yet';
  String expiresDate(String date) => _es ? 'Vence: $date' : 'Expires: $date';
  String get uploadDocument => _es ? 'Subir documento' : 'Upload Document';
  String get uploadingDocument =>
      _es ? 'Subiendo documento...' : 'Uploading document...';
  String get documentUploadedSuccessfully => _es
      ? '¡Documento subido exitosamente!'
      : 'Document uploaded successfully!';
  String get driversLicenseTitle =>
      _es ? 'Licencia de conducir' : "Driver's License";
  String get vehicleInsuranceTitle =>
      _es ? 'Seguro del vehículo' : 'Vehicle Insurance';
  String get vehicleRegistrationTitle =>
      _es ? 'Registro del vehículo' : 'Vehicle Registration';
  String get backgroundCheckTitle =>
      _es ? 'Verificación de antecedentes' : 'Background Check';
  String get profilePhotoTitle => _es ? 'Foto de perfil' : 'Profile Photo';
  String get vehiclePhotosTitle =>
      _es ? 'Fotos del vehículo' : 'Vehicle Photos';
  String get documentNumberLabel => _es ? 'Número de documento' : 'Document #';
  String get expiryDetailLabel => _es ? 'Vencimiento' : 'Expiry';
  String get uploadedLabel => _es ? 'Subido' : 'Uploaded';
  String get statusLabel => _es ? 'Estado' : 'Status';
  String get updateBtn => _es ? 'Actualizar' : 'Update';
  String get allDocumentsComplete => _es
      ? '¡Todos los documentos están al día!'
      : 'All documents are up to date!';
  String get documentNeedsUpdate =>
      _es ? 'Necesita actualización' : 'Needs update';
  String get documentExpiringSoon => _es ? 'Se vence pronto' : 'Expiring soon';
  String get documentExpired => _es ? 'Documento vencido' : 'Document expired';

  // ── Driver Vehicle Screen ──────────────────────────────────────────────────
  String get vehicleTitle => _es ? 'Vehículo' : 'Vehicle';
  String get vehicleInfoUpdated =>
      _es ? 'Información del vehículo actualizada' : 'Vehicle info updated';
  String failedToSave(String e) =>
      _es ? 'Error al guardar: $e' : 'Failed to save: $e';
  String get vehicleInspectionValid =>
      _es ? 'Inspección del vehículo válida' : 'Vehicle inspection valid';
  String get inspectionExpired =>
      _es ? 'Inspección vencida' : 'Inspection expired';
  String get nextInspectionDue => _es
      ? 'Próxima inspección: Mar 15, 2025'
      : 'Next inspection due: Mar 15, 2025';
  String get scheduleNewInspection => _es
      ? 'Por favor programa una nueva inspección'
      : 'Please schedule a new inspection';
  String get makeLabel => _es ? 'Marca' : 'Make';
  String get modelLabel => _es ? 'Modelo' : 'Model';
  String get yearLabel => _es ? 'Año' : 'Year';
  String get colorLabel => _es ? 'Color' : 'Color';
  String get vinLabel => _es ? 'VIN' : 'VIN';
  String get typeLabel => _es ? 'Tipo' : 'Type';

  // ── Driver Scheduled Trips Screen ─────────────────────────────────────────
  String get upcomingTrips => _es ? 'Próximos viajes' : 'Upcoming Rides';
  String get noUpcomingRides =>
      _es ? 'Sin viajes próximos' : 'No Upcoming Rides';
  String get scheduledRidesAssigned => _es
      ? 'Los viajes programados asignados a ti\naparecerán aquí'
      : 'Scheduled rides assigned to you\nwill appear here';
  String get notLoggedIn => _es ? 'No has iniciado sesión' : 'Not logged in';
  String get navigateToPickup =>
      _es ? 'Navegar al punto de recogida' : 'Navigate to Pickup';
  String get pickupCoordinatesNotAvailable => _es
      ? 'Coordenadas de recogida no disponibles'
      : 'Pickup coordinates not available';

  // ── Payout Methods Screen ──────────────────────────────────────────────────
  String get payoutMethodsTitle => _es ? 'Métodos de pago' : 'Payout methods';
  String get instantCashout => _es ? 'Retiro instantáneo' : 'Instant cashout';
  String get plaidDescription => _es
      ? 'Vincula tu banco o tarjeta de débito a través de Plaid para pagos instantáneos. Retira en cualquier momento.'
      : 'Link your bank or debit card via Plaid for instant payouts. Cash out anytime.';
  String get linkedAccounts => _es ? 'Cuentas vinculadas' : 'Linked accounts';
  String get plaidSecurityNote => _es
      ? 'Protegido por Stripe — cifrado bancario. Tus datos están seguros.'
      : 'Secured by Stripe — bank-level encryption. Your data is safe.';
  String get noPayoutMethods =>
      _es ? 'Sin métodos de pago' : 'No payout methods';
  String get connectBankPrompt => _es
      ? 'Conecta tu cuenta bancaria con Stripe\npara retiros instantáneos'
      : 'Connect your bank account with Stripe\nfor instant cashouts';
  String get poweredByPlaid => _es ? 'Powered by Stripe' : 'Powered by Stripe';
  String get defaultLabel => _es ? 'Predeterminado' : 'Default';
  String get bankTransfer => _es ? 'Transferencia bancaria' : 'Bank transfer';
  String get connecting => _es ? 'Conectando...' : 'Connecting...';
  String get connectBankAccount =>
      _es ? 'Conectar cuenta bancaria' : 'Connect bank account';
  String get addDebitCard =>
      _es ? 'Agregar tarjeta de débito' : 'Add debit card';
  String get linkBankAccount =>
      _es ? 'Vincular cuenta bancaria' : 'Link bank account';
  String get enterBankDetails => _es
      ? 'Ingresa los datos de tu banco para habilitar retiros.'
      : 'Enter your bank details to enable cashouts.';
  String get checking => _es ? 'Cheques' : 'Checking';
  String get savings => _es ? 'Ahorros' : 'Savings';
  String get bankName => _es ? 'Nombre del banco' : 'Bank name';
  String get routingNumber => _es ? 'Número de ruta' : 'Routing number';
  String get accountNumber => _es ? 'Número de cuenta' : 'Account number';
  String get bankNameHint =>
      _es ? 'ej. Chase, Bank of America' : 'e.g. Chase, Bank of America';
  String get routingNumberHint =>
      _es ? 'Número de ruta de 9 dígitos' : '9-digit routing number';
  String get accountNumberHint =>
      _es ? 'Tu número de cuenta' : 'Your account number';
  String get infoEncrypted => _es
      ? 'Tu información está cifrada y segura'
      : 'Your information is encrypted and secure';
  String get linkAccountBtn => _es ? 'Vincular cuenta' : 'Link account';
  String get addCardPrompt => _es
      ? 'Agrega tu tarjeta de débito para retiros instantáneos.'
      : 'Add your debit card for instant cashouts.';
  String get cardNumber => _es ? 'Número de tarjeta' : 'Card number';
  String get cardholderName => _es ? 'Nombre del titular' : 'Cardholder name';
  String get expiryLabel => _es ? 'Vencimiento' : 'Expiry';
  String get cardNumberHint => '1234 5678 9012 3456';
  String get nameOnCardHint => _es ? 'Nombre en la tarjeta' : 'Name on card';
  String get expiryHint => 'MM/YY';
  String get instantCashoutDebit => _es
      ? 'Retiro instantáneo disponible con tarjetas de débito'
      : 'Instant cashout available with debit cards';
  String get addCard => _es ? 'Agregar tarjeta' : 'Add card';
  String get addDebitCreditCard =>
      _es ? 'Agregar tarjeta de débito/crédito' : 'Add Debit/Credit Card';
  // Payment bottom sheet (Uber-style picker, 2026-08-04)
  String get moreOptions => _es ? 'Más opciones' : 'More options';
  // Driver trip screen: arrived, rider not aboard yet (2026-08-05).
  String get waitingForYourRider =>
      _es ? 'Esperando a tu pasajero…' : 'Waiting for your rider…';

  // Multi-stop v1 (2026-08-05)
  String get addStopLabel => _es ? 'Agregar parada' : 'Add stop';
  String get addStopHint =>
      _es ? 'Escribe la dirección de tu parada' : 'Type your stop address';
  String get newDestinationHint =>
      _es ? 'Escribe tu nuevo destino' : 'Type your new destination';
  String get areYouSureTitle => _es ? '¿Estás seguro?' : 'Are you sure?';
  String stopExtraCharge(String amount) => _es
      ? 'Se debitará un extra de $amount de tu método de pago al agregar esta parada.'
      : 'An extra $amount will be charged to your payment method for this stop.';
  String destChargeUp(String amount) => _es
      ? 'Tu tarifa subirá $amount con el nuevo destino.'
      : 'Your fare will go up by $amount with the new destination.';
  String destChargeDown(String amount) => _es
      ? 'Tu tarifa bajará $amount con el nuevo destino.'
      : 'Your fare will go down by $amount with the new destination.';
  String get stopAddedToast =>
      _es ? 'Parada agregada al viaje' : 'Stop added to your trip';
  String get destinationChangedToast =>
      _es ? 'Destino actualizado' : 'Destination updated';
  String get newStopBanner => _es ? 'Nueva parada' : 'New stop';
  String get destinationChangedBanner =>
      _es ? 'Destino cambiado' : 'Destination changed';
  String get stopLabelShort => _es ? 'PARADA' : 'STOP';
  String get routeChangeFailed => _es
      ? 'No se pudo actualizar la ruta. Intenta de nuevo.'
      : 'Could not update the route. Try again.';
  // Fase 2: the driver proposes, the rider confirms and pays.
  String get driverProposesStop => _es
      ? 'Tu driver propone agregar una parada'
      : 'Your driver proposes adding a stop';
  String get driverProposesDestination => _es
      ? 'Tu driver propone un nuevo destino'
      : 'Your driver proposes a new destination';
  // (decline ya existe más arriba — se reutiliza)
  String get proposalSentToRider => _es
      ? 'Propuesta enviada — esperando confirmación del rider'
      : 'Proposal sent — waiting for your rider to confirm';
  String get riderDeclinedProposal =>
      _es ? 'El rider no aceptó el cambio' : 'The rider declined the change';
  String get riderConfirmsAndPays => _es
      ? 'El rider confirma y paga el ajuste'
      : 'Your rider confirms and pays the adjustment';
  // Selected vehicle card when the tier has nobody nearby.
  String get noDriversNearArea =>
      _es ? 'No hay drivers cerca de tu área' : 'No drivers near your area';
  // Selected vehicle card in scheduled/airport mode — the ride is in the
  // future, so the wait-time line becomes a reservation note instead.
  String get availableToReserve =>
      _es ? 'Disponible para reservar' : 'Available to reserve';
  // Brand names — stay in English in both languages, like "Cruise Cash".
  String get cruiseBalance => 'Cruise Balance';
  String get cardEntryMobileOnly => _es
      ? 'La captura segura de tarjeta está disponible en la app móvil (iOS / Android).'
      : 'Secure card entry is available in the mobile app (iOS / Android).';
  String get bankLinkMobileOnly => _es
      ? 'La vinculación bancaria está disponible en la app móvil (iOS / Android).'
      : 'Bank linking is available in the mobile app (iOS / Android).';
  String get debitCardAdded => _es
      ? 'Tarjeta de débito agregada — retiro instantáneo habilitado'
      : 'Debit card added — instant cashout enabled';
  String get bankAccountLinked =>
      _es ? 'Cuenta bancaria vinculada' : 'Bank account linked';
  String get bankNeedsVerification => _es
      ? 'Tu banco necesita verificación antes de poder usarse. Stripe te enviará dos micro-depósitos; vuelve a vincularlo cuando los recibas.'
      : 'Your bank needs verification before it can be used. Stripe will send two microdeposits — link it again once they arrive.';
  String get failedToAddMethod =>
      _es ? 'Error al agregar método' : 'Failed to add method';
  String get removePayoutMethod =>
      _es ? '¿Eliminar método de pago?' : 'Remove payout method?';
  String confirmRemoveMethod(String name) => _es
      ? '¿Seguro que deseas eliminar "$name"?'
      : 'Are you sure you want to remove "$name"?';

  // ── Airport Terminal Sheet ─────────────────────────────────────────────────
  String get selectAirport => _es ? 'Seleccionar aeropuerto' : 'Select Airport';
  String get selectTerminal => _es ? 'Seleccionar terminal' : 'Select Terminal';
  String get confirmDetails => _es ? 'Confirmar detalles' : 'Confirm Details';
  String get searchAnyAirport =>
      _es ? 'Buscar cualquier aeropuerto...' : 'Search any airport...';
  String get moreAirports => _es ? 'Más aeropuertos' : 'More airports';
  String get noAirportsFound =>
      _es ? 'No se encontraron aeropuertos' : 'No airports found';
  String terminalsCount(int n) => _es ? '$n terminales' : '$n terminals';
  String get terminalLabel => _es ? 'Terminal' : 'Terminal';
  String get pickupZone => _es ? 'Zona de recogida' : 'Pickup Zone';
  String get mainTerminal => _es ? 'Terminal principal' : 'Main Terminal';
  String get arrivalsRideshare => _es
      ? 'Llegadas - Recogida de viajes compartidos'
      : 'Arrivals - Rideshare Pickup';
  String get airportRideTitle => _es ? 'Viaje al Aeropuerto' : 'Airport Ride';
  String get takeMeToAirport =>
      _es ? 'Llévame AL aeropuerto' : 'Take me TO the airport';
  String get flyingOutSubtitle =>
      _es ? 'Voy a tomar un vuelo' : 'I\'m flying out';
  String get pickMeUpFromAirport =>
      _es ? 'Recógeme EN el aeropuerto' : 'Pick me up FROM the airport';
  String get justLandedSubtitle => _es ? 'Acabo de aterrizar' : 'I just landed';
  String get selectYourAirline =>
      _es ? 'Selecciona tu aerolínea' : 'Select Your Airline';
  String get whichAirlineFlying =>
      _es ? '¿Con qué aerolínea vuelas?' : 'Which airline are you flying?';
  String get terminalAutoSelectedLabel =>
      _es ? 'auto-seleccionada' : 'auto-selected';
  String get selectTerminalAndDoor =>
      _es ? 'Terminal y Puerta de Llegada' : 'Select Terminal & Door';
  String get whichTerminalArrived =>
      _es ? '¿En qué terminal llegaste?' : 'Which terminal did you arrive at?';
  String get selectArrivalDoor =>
      _es ? 'Selecciona tu puerta de llegada' : 'Select Your Arrival Door';
  String get confirmAirportDropOff =>
      _es ? 'Confirmar Bajada en Aeropuerto' : 'Confirm Airport Drop-Off';
  String get confirmAirportPickupBtn =>
      _es ? 'Confirmar Recogida en Aeropuerto' : 'Confirm Airport Pickup';
  String get flightNumberRequiredLabel =>
      _es ? 'Número de Vuelo (requerido)' : 'Flight Number (required)';
  String get flightNumberRequiredError => _es
      ? 'Número de vuelo requerido — el conductor rastreará retrasos'
      : 'Flight number required — driver will track delays';
  String get driverWillDropAtDepartures => _es
      ? 'Tu conductor te dejará en el nivel de salidas'
      : 'Your driver will drop you at the departures level';
  String get driverWillWaitAtDoor => _es
      ? 'Tu conductor te esperará en la puerta de llegadas'
      : 'Your driver will wait for you at the arrival door';
  String get airlineLabel => _es ? 'Aerolínea' : 'Airline';
  String get arrivalDoorLabel => _es ? 'Puerta de Llegada' : 'Arrival Door';
  String get stepDirection => _es ? 'Dirección' : 'Direction';
  String get stepAirport => _es ? 'Aeropuerto' : 'Airport';
  String get stepDetails => _es ? 'Detalles' : 'Details';
  String get stepConfirm => _es ? 'Confirmar' : 'Confirm';

  // ── Pickup/Dropoff Search Screen ───────────────────────────────────────────
  String get pickupLocationHint =>
      _es ? 'Lugar de recogida' : 'Pickup location';
  String get whereToHint => _es ? '¿A dónde vas?' : 'Where to?';
  String setAddressTitle(String place) =>
      _es ? 'Establecer dirección de $place' : 'Set $place address';

  // ── Ride Request / Schedule Booking Screens ────────────────────────────────
  String get nowLabel => _es ? 'Ahora' : 'Now';
  String get scheduleLabel => _es ? 'Programar' : 'Schedule';
  // Matches the Shopify widget's step 3 heading
  // (vipRide__pricesTitle in 005_09-28-46_260627b.liquid).
  String get chooseARide => _es ? 'Elige un vehículo' : 'Choose a vehicle';
  String get bestBadge => _es ? 'MEJOR' : 'BEST';
  String get premiumBadge => 'PREMIUM';
  String get economyBadge => _es ? 'CONFORT' : 'COMFORT';
  String get comfortBadge => 'COMFORT';
  String get requestRideBtn => _es ? 'Solicitar viaje' : 'Request Ride';
  String get lookingForRide => _es ? 'Buscando conductor' : 'Looking for ride';
  String get paymentDeclined => _es ? 'Pago rechazado' : 'Payment Declined';
  String get noPaymentMethod =>
      _es ? 'Sin método de pago' : 'No payment method';
  String get cardNotValid => _es ? 'Tarjeta no válida' : 'Card not valid';
  String get pleaseAddPaymentMethod => _es
      ? 'Por favor agrega un método de pago antes de solicitar un viaje.'
      : 'Please add a payment method before requesting a ride.';
  String get cardCouldNotBeVerified => _es
      ? 'Tu tarjeta guardada no pudo ser verificada. Por favor actualiza tu tarjeta e intenta de nuevo.'
      : 'Your saved card could not be verified. Please update your card and try again.';
  String get paymentMethodDeclined => _es
      ? 'Tu método de pago fue rechazado. Prueba un método diferente o actualiza los datos de tu tarjeta.'
      : 'Your payment method was declined. Please try a different payment method or update your card details.';
  String get rideScheduledSuccessfully =>
      _es ? '¡Viaje programado exitosamente!' : 'Ride scheduled successfully!';
  String failedToScheduleRide(String e) =>
      _es ? 'Error al programar viaje: $e' : 'Failed to schedule ride: $e';
  String get enterBothPickupAndDestination =>
      _es ? 'Ingresa recogida y destino' : 'Enter both pickup and destination';
  String get pleaseAddPaymentFirst => _es
      ? 'Por favor agrega un método de pago primero'
      : 'Please add a payment method first';

  // ── Driver Online Screen ───────────────────────────────────────────────────
  String get seeEarningsTrends =>
      _es ? 'Ver tendencias de ganancias' : 'See Earnings Trends';
  String get seeUpcomingPromotions =>
      _es ? 'Ver próximas promociones' : 'See upcoming promotions';
  String get seeDrivingTime =>
      _es ? 'Ver tiempo de manejo' : 'See driving time';
  String ridesAvailable(int n) => _es
      ? '$n ${n == 1 ? 'Viaje' : 'Viajes'} disponible${n == 1 ? '' : 's'}'
      : '$n Ride${n == 1 ? '' : 's'} Available';
  String get rerouting => _es ? 'Recalculando...' : 'Rerouting...';
  String get offRoute => _es ? 'Fuera de ruta' : 'Off route';
  String get routeOverview => _es ? 'RESUMEN DE RUTA' : 'ROUTE OVERVIEW';
  String get yourLocation => _es ? 'Tu ubicación' : 'Your Location';
  String get yourLiveLocation =>
      _es ? 'Tu ubicación en vivo' : 'Your live location';
  String get simulateArrival => _es ? 'Simular llegada' : 'Simulate arrival';
  String get submit => _es ? 'Enviar' : 'Submit';
  String get confirmPayment => _es ? 'Confirmar pago' : 'Confirm Payment';
  String get payNow => _es ? 'Pagar ahora' : 'Pay Now';
  String get currentPosition => _es ? 'Posición actual' : 'Current position';
  String get pickupLabel => _es ? 'Recogida' : 'Pickup';
  String get dropOffLabel => _es ? 'Destino' : 'Drop-off';
  String get passengerInstructionsLabel =>
      _es ? 'Instrucciones del pasajero' : 'Passenger instructions';
  // dropoffLabel (camelCase variant) is at line ~2097
  String get reject => _es ? 'Rechazar' : 'Reject';
  String get acceptRide => _es ? 'Aceptar viaje' : 'Accept Ride';
  String pickingUp(String name) =>
      _es ? 'Recogiendo a $name' : 'Picking up $name';
  String droppingOff(String name) =>
      _es ? 'Dejando a $name' : 'Dropping off $name';
  String get arrivedAtPickup =>
      _es ? 'LLEGUÉ AL PUNTO DE RECOGIDA' : 'ARRIVED AT PICKUP';
  String get arrived => _es ? 'LLEGADO' : 'ARRIVED';
  String get waitingForRider =>
      _es ? 'ESPERANDO AL PASAJERO' : 'WAITING FOR RIDER';
  String get startTrip => _es ? 'INICIAR VIAJE' : 'START TRIP';
  String get tripInProgress => _es ? 'VIAJE EN CURSO' : 'TRIP IN PROGRESS';
  String get finishTrip => _es ? 'FINALIZAR VIAJE' : 'FINISH TRIP';
  String get startNavigation => _es ? 'Iniciar navegación' : 'Start Navigation';
  String get headToPickup => _es ? 'Hacia pickup' : 'To pickup';
  String get headToDropOff =>
      _es ? 'Dirígete al punto de entrega' : 'Head to drop-off';
  String get headToDestination => _es ? 'Hacia destino' : 'To destination';
  String get tripNoLongerAvailable =>
      _es ? 'Viaje ya no disponible' : 'Trip no longer available';

  // ── Trip Complete / Nav UI ─────────────────────────────────────────────────
  String get tripComplete => _es ? 'Viaje completo' : 'Trip Complete';
  String get fareEarned => _es ? 'Tarifa ganada' : 'Fare earned';
  String get rateRider => _es ? 'Calificar pasajero' : 'Rate rider';
  String get totalLabel => _es ? 'Total' : 'Total';
  String get continueDriving =>
      _es ? 'Continuar conduciendo' : 'Continue Driving';
  String get cancelTrip => _es ? 'Cancelar viaje' : 'Cancel Trip';
  String get thenLabel => _es ? 'LUEGO' : 'THEN';
  String toLabel(String dest) => _es ? 'A $dest' : 'TO $dest';
  String get messagesLabel => _es ? 'Mensajes' : 'Messages';
  String get promotionsLabel => _es ? 'Promociones' : 'Promotions';
  String get analyticsLabel => _es ? 'Analíticas' : 'Analytics';
  String get lastTripLabel => _es ? 'Último viaje' : 'Last Trip';

  // ── Driver Promos Screen ─────────────────────────────────────────────────
  String get activePromotions =>
      _es ? 'PROMOCIONES ACTIVAS' : 'ACTIVE PROMOTIONS';
  String get upcomingPromotions =>
      _es ? 'PRÓXIMAS PROMOCIONES' : 'UPCOMING PROMOTIONS';
  String get surgeZoneTitle =>
      _es ? 'Zona de alta demanda' : 'Surge Zone Active';
  String get surgeZoneDesc => _es
      ? 'Gana más en zonas de alta demanda'
      : 'Earn more in high-demand areas';
  String get consecutiveBonus =>
      _es ? 'Bono por viajes consecutivos' : 'Consecutive Trip Bonus';
  String get consecutiveBonusDesc =>
      _es ? 'Completa 3 viajes seguidos' : 'Complete 3 trips in a row';
  String get nightOwlBonus => _es ? 'Bono nocturno' : 'Night Owl Bonus';
  String get nightOwlBonusDesc =>
      _es ? 'Conduce entre 10pm - 4am' : 'Drive between 10pm - 4am';
  String get weekendWarrior =>
      _es ? 'Guerrero de fin de semana' : 'Weekend Warrior';
  String get weekendWarriorDesc =>
      _es ? 'Completa 20 viajes Sáb-Dom' : 'Complete 20 trips Sat-Sun';
  String get airportBonus =>
      _es ? 'Bono de aeropuerto' : 'Airport Pickup Bonus';
  String get airportBonusDesc =>
      _es ? 'Recogidas en el aeropuerto' : 'Pickups at the airport';

  // ── Driver Analytics Screen ──────────────────────────────────────────────
  String get weeklyChart => _es ? 'GRÁFICO SEMANAL' : 'WEEKLY CHART';
  String get activityStats =>
      _es ? 'ESTADÍSTICAS DE ACTIVIDAD' : 'ACTIVITY STATS';
  String get tripsThisWeek => _es ? 'Viajes esta semana' : 'Trips this week';
  String get onlineHoursToday =>
      _es ? 'Horas en línea hoy' : 'Online hours today';
  String get onlineHoursWeek =>
      _es ? 'Horas en línea esta semana' : 'Online hours this week';
  String get avgPerTrip => _es ? 'Promedio por viaje' : 'Avg. per trip';

  // ── Driver Offers Screen ───────────────────────────────────────────────────
  String get goOfflineBtn => _es ? 'Desconectarse' : 'Go Offline';
  String get onlineStatus => _es ? 'EN LÍNEA' : 'ONLINE';
  String get acceptingRide => _es ? 'Aceptando viaje...' : 'Accepting ride...';
  String get findingRidesNearYou =>
      _es ? 'Buscando viajes cerca de ti...' : 'Finding rides near you...';
  String get lookingForRides =>
      _es ? 'Buscando viajes...' : 'Looking for rides...';
  String get newOffersWillAppear => _es
      ? 'Los nuevos viajes aparecerán aquí automáticamente'
      : 'New offers will appear here automatically';
  String get availableRides => _es ? 'Viajes disponibles' : 'Available Rides';
  String get skipOffer => _es ? 'SALTAR' : 'SKIP';
  String get acceptOffer => _es ? 'ACEPTAR' : 'ACCEPT';

  // ── Ride Request Screen ────────────────────────────────────────────────────
  String get tripCancelled => _es ? 'Viaje cancelado' : 'Trip cancelled';
  String get noDriversAvailableTitle =>
      _es ? 'Sin conductores disponibles' : 'No drivers available';
  String get noDriversAvailableMsg => _es
      ? 'No hay conductores disponibles cerca de tu zona en estos momentos. Por favor intenta de nuevo en unos minutos.'
      : 'There are no drivers available near your area right now. Please try again in a few minutes.';
  String get okBtn => _es ? 'Aceptar' : 'OK';
  String get fastRideLabel => _es ? 'Prioritario' : 'Priority';
  String requestRideWithPrice(String price) =>
      _es ? 'Solicitar viaje · \$$price' : 'Request Ride · \$$price';
  String get requestRide => _es ? 'Solicitar viaje' : 'Request Ride';
  String get premiumTier => 'PREMIUM';
  String get economyTier => 'COMFORT';
  String get comfortTier => 'COMFORT';
  String get paymentLabel => _es ? 'Pago' : 'Payment';
  String get tapToChange => _es ? 'Toca para cambiar' : 'Tap to change';
  String get notAddedTapToSetUp =>
      _es ? 'No agregado — toca para configurar' : 'Not added — tap to set up';
  String payPrice(String price) => _es ? 'Pagar $price' : 'Pay $price';
  String get addPaymentMethodMsg => _es
      ? 'Por favor agrega un método de pago antes de solicitar un viaje.'
      : 'Please add a payment method before requesting a ride.';
  String get cardNotValidMsg => _es
      ? 'Tu tarjeta guardada no pudo ser verificada. Por favor actualiza tu tarjeta e intenta de nuevo.'
      : 'Your saved card could not be verified. Please update your card and try again.';
  String get paymentDeclinedMsg => _es
      ? 'Tu método de pago fue rechazado. Por favor intenta con un método diferente o actualiza los datos de tu tarjeta.'
      : 'Your payment method was declined. Please try a different payment method or update your card details.';
  String get rideScheduledSuccess =>
      _es ? '¡Viaje programado exitosamente!' : 'Ride scheduled successfully!';
  String get paymentMethodLabel => _es ? 'Método de pago' : 'Payment method';
  String get notAdded => _es ? 'No agregado' : 'Not added';
  String get added => _es ? 'Agregado' : 'Added';
  String get addBtn => _es ? 'Agregar' : 'Add';
  String get managePaymentAccounts =>
      _es ? 'Administrar cuentas de pago' : 'Manage payment accounts';
  String get creditOrDebitCard =>
      _es ? 'Tarjeta de crédito o débito' : 'Credit or debit card';

  // ── Payment Retry System ────────────────────────────────────────────────────
  String get cardDeclined => _es ? 'Tarjeta rechazada' : 'Card declined';
  String get cardDeclinedMsg => _es
      ? 'Tu tarjeta fue rechazada por el banco. Intenta con otro método de pago.'
      : 'Your card was declined by the bank. Try a different payment method.';
  String get insufficientFunds =>
      _es ? 'Fondos insuficientes' : 'Insufficient funds';
  String get insufficientFundsMsg => _es
      ? 'No hay fondos suficientes en esta tarjeta. Intenta con otro método de pago.'
      : 'There are not enough funds on this card. Try a different payment method.';
  String get cardExpired => _es ? 'Tarjeta vencida' : 'Card expired';
  String get cardExpiredMsg => _es
      ? 'Tu tarjeta ha vencido. Por favor actualiza los datos de tu tarjeta.'
      : 'Your card has expired. Please update your card details.';
  String get invalidCardNumber => _es ? 'Número inválido' : 'Invalid number';
  String get invalidCardNumberMsg => _es
      ? 'El número de tarjeta es incorrecto. Por favor verifica los datos.'
      : 'The card number is incorrect. Please verify the details.';
  String get paypalDeclined => _es ? 'PayPal rechazado' : 'PayPal declined';
  String get paypalDeclinedMsg => _es
      ? 'PayPal no pudo procesar el pago. Intenta con otro método.'
      : 'PayPal could not process the payment. Try another method.';
  String get networkError => _es ? 'Error de conexión' : 'Network error';
  String get networkErrorMsg => _es
      ? 'Hubo un problema de conexión. Verifica tu internet e intenta de nuevo.'
      : 'There was a connection problem. Check your internet and try again.';
  String get tryDifferentPaymentMethod =>
      _es ? 'Usar otro método de pago' : 'Try different payment method';
  String get retryConnection =>
      _es ? 'Reintentar conexión' : 'Retry connection';
  String retryWithSameMethod(String method) =>
      _es ? 'Reintentar con $method' : 'Retry with $method';
  String get addNewCard => _es ? 'Agregar nueva tarjeta' : 'Add new card';
  String get genericPaymentError => _es
      ? 'Hubo un problema con el pago. Intenta de nuevo o usa otro método.'
      : 'There was a problem with the payment. Try again or use another method.';
  String get fareEstimateError =>
      _es ? 'Tarifa no disponible' : 'Fare unavailable';
  String get fareEstimateErrorMsg => _es
      ? 'No pudimos calcular una tarifa válida para esta ruta. Ajusta el origen o el destino e inténtalo de nuevo.'
      : "We couldn't calculate a valid fare for this route. Adjust the pickup or destination and try again.";

  String get cancelRideMsg => _es
      ? '¿Estás seguro de que quieres cancelar tu solicitud de viaje?'
      : 'Are you sure you want to cancel your ride request?';
  String get keepWaiting => _es ? 'Seguir esperando' : 'Keep Waiting';
  String get yesCancelBtn => _es ? 'Sí, cancelar' : 'Yes, Cancel';
  String get destination => _es ? 'Destino' : 'Destination';

  // ── Promo Code Screen ──────────────────────────────────────────────────────

  // ── Payment Method Screen ─────────────────────────────────────────────────
  String get setupGooglePayFirst => _es
      ? 'Configura Google Pay en Google Wallet primero.'
      : 'Set up Google Pay in Google Wallet first.';

  // ── Payment Accounts Screen ────────────────────────────────────────────────
  String get paymentAccounts => _es ? 'Cuentas de pago' : 'Payment accounts';
  String get linkAccountsMsg => _es
      ? 'Vincula tus cuentas para pagar más rápido.'
      : 'Link your accounts so you can pay faster.';

  // ── Credit Card Screen ─────────────────────────────────────────────────────
  String get addYourCard => _es ? 'Agrega tu tarjeta' : 'Add your card';
  String get enterCardDetails => _es
      ? 'Ingresa los datos de tu tarjeta de crédito o débito.'
      : 'Enter your credit or debit card details.';
  String get nameOnCard => _es ? 'Nombre en la tarjeta' : 'Name on card';
  String get zipPostalCode => _es ? 'Código postal' : 'ZIP / Postal code';
  String get addressLabel => _es ? 'Dirección' : 'Address';
  String get cityLabel => _es ? 'Ciudad' : 'City';
  String get dayLabel => _es ? 'Día' : 'Day';
  String get agreeToStripeAgreement => _es
      ? 'Acepto el Acuerdo de Cuenta Conectada de Stripe'
      : "I agree to Stripe's Connected Account Agreement";
  String get securedByStripe => _es
      ? 'Tu información está encriptada y segura — nunca la compartimos.'
      : 'Your information is encrypted and secure — never shared.';
  String get billingAddressHint =>
      _es ? 'Dirección de facturación' : 'Billing address';
  String get aptSuiteOptional =>
      _es ? 'Apto / Suite (opcional)' : 'Apt / Suite (optional)';
  String get cityHint => _es ? 'Ciudad' : 'City';
  String get stateHint => _es ? 'Estado' : 'State';
  String get somethingWentWrong => _es
      ? 'Algo salió mal. Por favor intenta de nuevo.'
      : 'Something went wrong. Please try again.';

  // ── PayPal Checkout Screen ─────────────────────────────────────────────────
  String get couldNotConnectPaypal =>
      _es ? 'No se pudo conectar con PayPal.' : 'Could not connect to PayPal.';
  String get checkPaypalCredentials => _es
      ? 'Asegúrate de que tus credenciales de PayPal estén configuradas en env.dart.'
      : 'Make sure your PayPal credentials are set in env.dart.';

  // ── Schedule Booking Screen ────────────────────────────────────────────────
  String get airportRide => _es ? 'Viaje al aeropuerto' : 'Airport ride';
  String get enterAddressesToSeeRoute => _es
      ? 'Ingresa las direcciones para ver la ruta'
      : 'Enter addresses to see route';
  String get bookScheduledRide => _es ? 'Reservar ahora' : 'Reserve Now';
  String get enterBothAddresses => _es
      ? 'Ingresa el punto de recogida y destino'
      : 'Enter both pickup and destination';
  String get rideScheduled => _es ? 'Viaje programado' : 'Ride scheduled';
  String get readyLabel => _es ? 'Listo' : 'Ready';
  String get bestLabel => _es ? 'MEJOR' : 'BEST';

  // ── Airport Terminal Sheet ─────────────────────────────────────────────────
  String get selectZone => _es ? 'Selecciona zona' : 'Select Zone';
  String get flightNumber => _es ? 'Número de vuelo' : 'Flight number';
  String get confirmLabel => _es ? 'Confirmar' : 'Confirm';

  // ── Face Liveness Screen ───────────────────────────────────────────────────
  String get faceVerification =>
      _es ? 'Verificación facial' : 'Face Verification';
  String get initializingCamera =>
      _es ? 'Inicializando cámara...' : 'Initializing camera...';
  String get lookStraight =>
      _es ? 'Mira directamente a la cámara' : 'Look straight at the camera';
  String get centerFaceInOval =>
      _es ? 'Centra tu rostro en el óvalo' : 'Center your face in the oval';
  String get blinkBothEyes => _es ? 'Parpadea ambos ojos' : 'Blink both eyes';
  String get smileForPhoto =>
      _es ? 'Sonríe para la foto' : 'Smile for the photo';
  String get livenessVerified =>
      _es ? '¡Verificación completada!' : 'Liveness Verified!';
  String get capturingPhoto =>
      _es ? 'Capturando tu foto...' : 'Capturing your photo...';
  String get recordingVerification =>
      _es ? 'Grabando verificación...' : 'Recording verification...';

  // ── Payment Method Screen (extra) ──────────────────────────────────────────
  String get confirmApplePay =>
      _es ? 'Confirmar Apple Pay' : 'Confirm Apple Pay';
  String get applePayPrompt => _es
      ? 'Toca el botón de abajo para confirmar Apple Pay para los viajes de Cruise.'
      : 'Tap the button below to confirm Apple Pay for Cruise rides.';
  String googlePayError(String error) =>
      _es ? 'Error de Google Pay: $error' : 'Google Pay error: $error';
  String applePayError(String error) =>
      _es ? 'Error de Apple Pay: $error' : 'Apple Pay error: $error';
  String get cruiseAccountVerificationDesc => _es
      ? 'Verificación de cuenta Cruise (\$1.00 reembolsable)'
      : 'Cruise account verification (\$1.00 refundable)';

  // ── Payment Accounts Screen (extra) ────────────────────────────────────────
  String get setupApplePayInSettings => _es
      ? 'Configura Apple Pay en Wallet y Apple Pay en Configuración.'
      : 'Set up Apple Pay in Wallet & Apple Pay in Settings.';
  String get googlePaySetUpInWallet => _es
      ? 'Google Pay (configurar en Wallet)'
      : 'Google Pay (set up in Wallet)';
  String get applePaySetUpInWallet =>
      _es ? 'Apple Pay (configurar en Wallet)' : 'Apple Pay (set up in Wallet)';
  String get paymentSecurityNote => _es
      ? 'Tu información de pago está cifrada y almacenada de forma segura. Cruise nunca ve los detalles de tu tarjeta.'
      : 'Your payment information is securely encrypted and stored. Cruise never sees your card details.';
  String get confirmGooglePayVerifyMsg => _es
      ? 'Toca el botón de abajo para verificar que tu cuenta de Google Pay esté lista para los viajes de Cruise.'
      : 'Tap the button below to verify your Google Pay account is ready for Cruise rides.';
  String get confirmApplePayVerifyMsg => _es
      ? 'Toca el botón de abajo para verificar que tu cuenta de Apple Pay esté lista para los viajes de Cruise.'
      : 'Tap the button below to verify your Apple Pay account is ready for Cruise rides.';

  // ── Schedule Booking Screen (extra) ────────────────────────────────────────
  String get tapToSetUp => _es ? 'Toca para configurar' : 'Tap to set up';
  String get creditCardLabel2 => _es ? 'Tarjeta de crédito' : 'Credit card';
  String scheduledForDate(String dateTime) =>
      _es ? '¡Programado para $dateTime!' : 'Scheduled for $dateTime!';
  String rideScheduledMsg(String dateTime) => _es
      ? 'Tu viaje el $dateTime ha sido confirmado.'
      : 'Your ride on $dateTime has been confirmed.';
  String failedToBook(String error) =>
      _es ? 'Error al reservar: $error' : 'Failed to book: $error';
  String airportCodeTapToRemove(String code) =>
      _es ? '$code — toca para quitar' : '$code — tap to remove';

  // ── Airport Terminal Sheet (extra) ─────────────────────────────────────────
  String get flightNumberOptional =>
      _es ? 'Número de Vuelo (opcional)' : 'Flight Number (optional)';
  String get flightNumberHint => _es ? 'ej. AA 1234' : 'e.g. AA 1234';
  String get flightTrackingNote => _es
      ? 'Tu conductor rastreará tu vuelo y ajustará la hora de recogida si hay retraso.'
      : 'Your driver will track your flight and adjust pickup time if delayed.';
  String get confirmAirportDetails =>
      _es ? 'Confirmar Detalles del Aeropuerto' : 'Confirm Airport Details';
  String get airportSurchargeLabel =>
      _es ? 'Recargo de aeropuerto' : 'Airport Surcharge';

  // ── Face Liveness Screen (extra) ───────────────────────────────────────────
  String get slowlyTurnHead => _es
      ? 'Gira lentamente la cabeza hacia un lado'
      : 'Slowly turn your head to the side';
  String get turnLeftOrRight => _es
      ? 'Gira a la izquierda o derecha, luego regresa'
      : 'Turn left or right, then back';
  String get closeAndReopenEyes =>
      _es ? 'Cierra y vuelve a abrir los ojos' : 'Close and reopen your eyes';
  String get giveUsBestSmile =>
      _es ? '¡Danos tu mejor sonrisa!' : 'Give us your best smile!';

  // ── About Screen ──────────────────────────────────────────────────────────
  String get aboutTitle => _es ? 'Acerca de' : 'About';

  // ── Driver Profile Screen ──────────────────────────────────────────────────
  String get profileTitle => _es ? 'Perfil' : 'Profile';
  String get deliveries => _es ? 'Entregas' : 'Deliveries';
  String get lifetimeHighlights =>
      _es ? 'Logros de por vida' : 'Lifetime highlights';

  // ── Cruise Level Screen ────────────────────────────────────────────────────
  String get cruiseLevel => _es ? 'Nivel Cruise' : 'Cruise Level';
  String get earnPointsUnlockRewards => _es
      ? 'Gana puntos y desbloquea recompensas'
      : 'Earn points and unlock rewards';
  String get currentLevel => _es ? 'Nivel actual' : 'Current level';
  String get allLevels => _es ? 'Todos los niveles' : 'All levels';

  // ── Promo (extra) ─────────────────────────────────────────────────────────
  String dollarOff(String amount) => '\$$amount OFF';
  String percentOff(int percent) => '$percent% OFF';

  // ── Credit Card (extra) ────────────────────────────────────────────────────
  String get cardCouldNotBeProcessed => _es
      ? 'La tarjeta no pudo ser procesada.'
      : 'Card could not be processed.';

  // ── PayPal (extra) ─────────────────────────────────────────────────────────
  String get paypal => 'PayPal';

  // ── Payment Method / Accounts (extra) ──────────────────────────────────────
  String get cruiseCash => 'Cruise Cash';
  String cardAddedMsg(String card) => _es ? '$card agregada' : '$card added';
  String get arrivalsRidesharePickup =>
      _es ? 'Llegadas - Recogida Rideshare' : 'Arrivals - Rideshare Pickup';

  // ── Driver Profile Screen (extra) ──────────────────────────────────────────
  String get journeyWithCruise =>
      _es ? 'Trayectoria con Cruise' : 'Journey with Cruise';
  String get badges => _es ? 'Insignias' : 'Badges';
  String get viewPublicProfile =>
      _es ? 'Ver perfil público' : 'View public profile';
  String get yourMode => _es ? 'Tu modo' : 'Your mode';
  String get advantageMode => _es ? 'Modo ventaja' : 'Advantage mode';
  String get cruiseProLabel => 'Cruise Pro';
  String get badgeFirstTrip => _es ? 'Primer viaje' : 'First Trip';
  String get badge50Trips => _es ? '50 Viajes' : '50 Trips';
  String get badge100Club => _es ? 'Club 100' : '100 Club';
  String get badge500Elite => _es ? '500 Élite' : '500 Elite';
  String get badgeAnniversary => _es ? 'Aniversario' : 'Anniversary';
  String get completeTripsToEarnBadges => _es
      ? '¡Completa viajes para ganar insignias!'
      : 'Complete trips to earn badges!';
  String get closeLabel => _es ? 'Cerrar' : 'Close';
  String get customerLabel => _es ? 'Cliente' : 'Customer';
  String get negativeLabel => _es ? 'Negativo' : 'Negative';
  String lastAcceptedTrips(int canceled, int total) => _es
      ? '$canceled/$total últimos viajes aceptados'
      : '$canceled/$total last accepted trips';
  String get tripsAccepted => _es ? 'Viajes aceptados' : 'Trips accepted';
  String get completedTrips => _es ? 'Viajes completados' : 'Completed trips';
  String get canceledTrips => _es ? 'Viajes cancelados' : 'Canceled trips';
  String get howCancellationCalculated => _es
      ? 'Cómo se calcula la tasa de cancelación'
      : 'How cancellation rate is calculated';
  String get whyCancellationMatters => _es
      ? 'Por qué importa la tasa de cancelación'
      : 'Why cancellation rate matters';
  String lastExclusiveRequests(int accepted, int total) => _es
      ? '$accepted/$total últimas solicitudes exclusivas'
      : '$accepted/$total last exclusive requests';
  String get exclusiveTripRequests =>
      _es ? 'Solicitudes de viaje exclusivas' : 'Exclusive trip requests';
  String get acceptedLabel => _es ? 'Aceptadas' : 'Accepted';
  String get declinedLabel => _es ? 'Rechazadas' : 'Declined';
  String get howAcceptanceCalculated => _es
      ? 'Cómo se calcula la tasa de aceptación'
      : 'How acceptance rate is calculated';
  String get whyAcceptanceMatters => _es
      ? 'Por qué importa la tasa de aceptación'
      : 'Why acceptance rate matters';
  String get onTimeLabel => _es ? 'A tiempo' : 'On time';
  String get lateLabel => _es ? 'Tarde' : 'Late';
  String get basedOnLastRatings => _es
      ? 'Basado en tus últimas calificaciones de clientes'
      : 'Based on your last ratings from customers';
  String basedOnLastRequests(int n) => _es
      ? 'Basado en tus últimas $n solicitudes aceptadas'
      : 'Based on your last $n accepted requests';
  String get feedbackFromCustomers =>
      _es ? 'Comentarios de clientes' : 'Feedback from customers';
  String get feedbackProfessional =>
      _es ? 'Servicio profesional' : 'Professional service';
  String get feedbackCleanVehicle => _es ? 'Vehículo limpio' : 'Clean vehicle';
  String get feedbackGreatNavigation =>
      _es ? 'Gran navegación' : 'Great navigation';
  String get feedbackFriendlyDriver =>
      _es ? 'Conductor amigable' : 'Friendly driver';
  String get howCancellationCalculatedBody => _es
      ? 'Tu tasa de cancelación se calcula dividiendo los viajes que cancelaste entre el total de viajes aceptados en tus últimas solicitudes.'
      : 'Your cancellation rate is calculated by dividing the trips you canceled by the total accepted trips in your recent requests.';
  String get whyCancellationMattersBody => _es
      ? 'Una tasa de cancelación baja muestra a los pasajeros y a Cruise que eres un conductor confiable. Cancelaciones frecuentes pueden afectar tu acceso a viajes exclusivos.'
      : 'A low cancellation rate shows riders and Cruise that you are a reliable driver. Frequent cancellations may affect your access to exclusive trips.';
  String get howAcceptanceCalculatedBody => _es
      ? 'Tu tasa de aceptación se calcula dividiendo las solicitudes exclusivas que aceptaste entre el total de solicitudes exclusivas recibidas.'
      : 'Your acceptance rate is calculated by dividing the exclusive requests you accepted by the total exclusive requests received.';
  String get whyAcceptanceMattersBody => _es
      ? 'Una alta tasa de aceptación te da prioridad en viajes exclusivos y demuestra compromiso con la plataforma.'
      : 'A high acceptance rate gives you priority for exclusive trips and shows commitment to the platform.';

  // ── Cruise Level Screen (extra) ────────────────────────────────────────────
  String pointsCount(int points) => _es ? '$points puntos' : '$points points';
  String pointsToNextLevel(int points, String level) =>
      _es ? '$points puntos para $level' : '$points points to $level';
  String requirementsForLevel(String level) =>
      _es ? 'Requisitos para $level' : 'Requirements for $level';
  String get currentLabel => _es ? 'Actual' : 'Current';
  String pointsAndRewards(int points, int rewards) => _es
      ? '$points puntos · $rewards recompensas'
      : '$points points · $rewards rewards';
  String get yourCurrentLevel => _es ? 'Tu nivel actual' : 'Your current level';
  String get requirements => _es ? 'Requisitos' : 'Requirements';
  String get rewards => _es ? 'Recompensas' : 'Rewards';
  String get keepGoing => _es ? '¡Sigue adelante!' : 'Keep going!';
  String get viewRewards => _es ? 'Ver recompensas' : 'View rewards';
  String reqAcceptance(int min) =>
      _es ? 'Aceptación ≥ $min%' : 'Acceptance ≥ $min%';
  String reqCancellation(int max) =>
      _es ? 'Cancelación ≤ $max%' : 'Cancellation ≤ $max%';
  String reqSatisfaction(int min) =>
      _es ? 'Satisfacción ≥ $min%' : 'Satisfaction ≥ $min%';
  String reqOnTime(int min) => _es ? 'Puntualidad ≥ $min%' : 'On-time ≥ $min%';
  String get rewardBasicSupport =>
      _es ? 'Soporte básico para conductores' : 'Basic driver support';
  String get rewardStandardAccess =>
      _es ? 'Acceso estándar a viajes' : 'Standard trip access';
  String get rewardFuelTips =>
      _es ? 'Consejos de ahorro de combustible' : 'Fuel savings tips';
  String get rewardPriorityAccess =>
      _es ? 'Acceso prioritario a viajes' : 'Priority trip access';
  String get rewardCashback3 =>
      _es ? '3% de reembolso en gasolina' : '3% cash-back on gas';
  String get rewardPremiumSupport =>
      _es ? 'Soporte premium 24/7' : '24/7 premium support';
  String get rewardTuitionDiscount => _es
      ? 'Descuento en matrícula universitaria'
      : 'University tuition discount';
  String get rewardAllGold =>
      _es ? 'Todas las recompensas Gold' : 'All Gold rewards';
  String get rewardCashback6 =>
      _es ? '6% de reembolso en gasolina' : '6% cash-back on gas';
  String get rewardMaintenanceDiscount => _es
      ? 'Descuentos en mantenimiento vehicular'
      : 'Vehicle maintenance discounts';
  String get rewardAirportQueue =>
      _es ? 'Cola prioritaria en aeropuerto' : 'Priority airport queue';
  String get rewardExclusivePromos =>
      _es ? 'Promociones exclusivas' : 'Exclusive promotions';
  String get rewardAllPlatinum =>
      _es ? 'Todas las recompensas Platinum' : 'All Platinum rewards';
  String get rewardCashback10 =>
      _es ? '10% de reembolso en gasolina' : '10% cash-back on gas';
  String get rewardFreeInspections =>
      _es ? 'Inspecciones vehiculares gratuitas' : 'Free vehicle inspections';
  String get rewardConcierge =>
      _es ? 'Soporte de conserje dedicado' : 'Dedicated concierge support';
  String get rewardEarningsMultiplier => _es
      ? 'Multiplicador de ganancias más alto'
      : 'Highest earnings multiplier';
  String get rewardDiamondEvents =>
      _es ? 'Eventos exclusivos Diamond' : 'Exclusive Diamond events';

  // ── Map Screen ─────────────────────────────────────────────────────────────
  String get detectingLocation =>
      _es ? 'Detectando tu ubicación...' : 'Detecting your location...';
  String get invalidCoordinatesError => _es
      ? 'La dirección no tiene coordenadas válidas.'
      : 'The address has no valid coordinates.';
  String get routeNotFoundError => _es
      ? 'No se pudo trazar una ruta real. Verifica origen/destino e intenta de nuevo.'
      : 'Could not find a route. Please verify origin/destination and try again.';
  String get selectValidDestination => _es
      ? 'Selecciona un destino válido para continuar.'
      : 'Select a valid destination to continue.';
  String get planYourDestination =>
      _es ? 'Planifica tu destino' : 'Plan your destination';
  String get moveMapChooseDestination => _es
      ? 'Mueve el mapa y elige a dónde ir'
      : 'Move map and choose where to go';
  String get planYourRide => _es ? 'Planifica tu viaje' : 'Plan your ride';
  String get forMe => _es ? 'Para mí' : 'For me';
  String get pickupHint => _es ? 'Recogida' : 'Pickup';
  String get addressResultsError => _es
      ? 'No se pudieron cargar los resultados de dirección.'
      : 'Could not load address results.';
  String get gatheringOptions =>
      _es ? 'Recopilando opciones' : 'Gathering options';
  String discountApplied(int percent) =>
      _es ? '$percent% de descuento aplicado' : '$percent% discount applied';
  String get selectYourRide => _es ? 'Selecciona tu viaje' : 'Select your ride';
  String get fasterTag => _es ? 'Más rápido' : 'Faster';
  String get pickupNow => _es ? 'Recoger ahora' : 'Pickup now';
  String get pickupLater => _es ? 'Recoger después' : 'Pickup later';
  String get whenNeedRide =>
      _es ? '¿Cuándo necesitas un viaje?' : 'When do you need a ride?';
  String get nowSubtitle =>
      _es ? 'Pide un viaje, sube y vámonos' : 'Request a ride, hop in, and go';
  String get laterLabel => _es ? 'Después' : 'Later';
  String get laterSubtitle => _es
      ? 'Reserva para mayor tranquilidad'
      : 'Reserve for extra peace of mind';
  String get nextButton => _es ? 'Siguiente' : 'Next';
  String get pickDate => _es ? 'Elige una fecha' : 'Pick a date';
  String get pickTime => _es ? 'Elige una hora' : 'Pick a time';
  String get confirmButton => _es ? 'Confirmar' : 'Confirm';
  String get confirmPickupSpot =>
      _es ? 'Confirma el punto de recogida' : 'Confirm pickup spot';
  String get moveMapAdjustPickup => _es
      ? 'Mueve el mapa para ajustar tu recogida'
      : 'Move the map to adjust your pickup';
  String scheduledFor(String text) =>
      _es ? 'Programado para $text' : 'Scheduled for $text';
  String get addNoteForDriver =>
      _es ? 'Agregar nota para el conductor' : 'Add note for driver';
  String get selectPayment => _es ? 'Seleccionar pago' : 'Select payment';
  String get noteForDriver =>
      _es ? 'Nota para el conductor' : 'Note for driver';
  String get noteHint => _es
      ? 'ej. Estoy en la entrada principal'
      : "e.g. I'm at the front entrance";
  String get saveButton => _es ? 'Guardar' : 'Save';
  String promoDiscountApplied(int percent) => _es
      ? '$percent% de descuento promocional aplicado'
      : '$percent% promotional discount applied';
  String payAmount(String price) => _es ? 'Pagar $price' : 'Pay $price';
  String bookScheduledRidePrice(String price) =>
      _es ? 'Reservar ahora · $price' : 'Reserve Now · $price';
  String get paymentMethodTitle => _es ? 'Método de pago' : 'Payment method';
  String get addedLabel => _es ? 'Agregado' : 'Added';
  String get addButton => _es ? 'Agregar' : 'Add';
  String get notAddedTapSetup =>
      _es ? 'No agregado — toca para configurar' : 'Not added — tap to set up';
  String get googlePayNotAvailable => _es
      ? 'Google Pay no está disponible en este dispositivo.'
      : 'Google Pay is not available on this device.';
  String get completeSetupQuestion =>
      _es ? '¿Completaste la configuración?' : 'Did you complete setup?';
  String confirmLinkedAccount(String name) => _es
      ? 'Confirma que vinculaste tu cuenta de $name.'
      : 'Confirm that you linked your $name account.';
  String get notYet => _es ? 'Aún no' : 'Not yet';
  String get yesLinked => _es ? 'Sí, está vinculado' : "Yes, it's linked";
  String linkedSuccessfully(String name) =>
      _es ? '$name vinculado exitosamente' : '$name linked successfully';
  String get lookingForDriver =>
      _es ? 'Buscando tu conductor' : 'Looking for your driver';
  String get driverFound => _es ? '¡Conductor encontrado!' : 'Driver found!';
  String get isOnTheWay => _es ? 'está en camino' : 'is on the way';
  String findingBestNearby(String name) => _es
      ? 'Encontrando el mejor $name cercano'
      : 'Finding the best $name nearby';
  String arrivingIn(String name, String eta) =>
      _es ? '$name · llegando en $eta' : '$name · arriving in $eta';
  String get dropoffLabel => _es ? 'Destino' : 'Drop-off';
  String get driverContacted =>
      _es ? 'Conductor contactado.' : 'Driver contacted.';
  String get callDriver => _es ? 'Llamar conductor' : 'Call Driver';
  String get stopSearchingQuestion =>
      _es ? '¿Dejar de buscar?' : 'Stop Searching?';
  String get cancelRideConfirmation => _es
      ? '¿Estás seguro de que quieres cancelar este viaje? Puede aplicar una tarifa de cancelación.'
      : 'Are you sure you want to cancel this ride? A cancellation fee may apply.';
  String get stopSearchingConfirmation => _es
      ? '¿Estás seguro de que quieres dejar de buscar un conductor?'
      : 'Are you sure you want to stop looking for a driver?';
  String get keepRide => _es ? 'Mantener viaje' : 'Keep Ride';
  String get cancelButton => _es ? 'Cancelar' : 'Cancel';
  String get tripCancelledByOperator => _es
      ? 'Tu viaje ha sido cancelado por el operador. Por favor solicita un nuevo viaje.'
      : 'Your trip has been cancelled by the operator. Please request a new ride.';
  String get okButton => _es ? 'OK' : 'OK';
  String arrivalTime(String time) => _es ? 'Llegada $time' : 'Arrival $time';
  String etaLabel(String eta) => 'ETA $eta';
  String get addOrChange => _es ? 'Agregar o\nCambiar' : 'Add or\nChange';
  String get howsYourRide =>
      _es ? '¿Cómo va tu viaje?' : "How's your ride going?";
  String get rateOrTip => _es ? 'Calificar o propina' : 'Rate or tip';
  String driverAtPickup(String name) =>
      _es ? '$name está en el punto de recogida' : '$name is at pickup';
  String driverOnTheWay(String name) =>
      _es ? '$name está en camino' : '$name is on the way';
  String get enterAddressesFirst => _es
      ? 'Ingresa las direcciones de recogida y destino primero'
      : 'Enter pickup and destination addresses first';
  String rideScheduledFor(String label) =>
      _es ? '¡Viaje programado para $label!' : 'Ride scheduled for $label!';
  String get rideScheduledTitle => _es ? 'Viaje programado' : 'Ride scheduled';
  String rideScheduledMessage(String label) => _es
      ? 'Tu viaje de $label ha sido confirmado.'
      : 'Your $label ride has been confirmed.';
  String get searchingDriverTitle =>
      _es ? 'Buscando conductor' : 'Searching driver';
  String searchingDriverMessage(String name) => _es
      ? 'Estamos buscando el mejor $name cercano.'
      : 'We are finding the best $name nearby.';
  String get driverAssignedTitle =>
      _es ? 'Conductor asignado' : 'Driver assigned';
  String driverAssignedMessage(String name, String eta) =>
      _es ? '$name está en camino en $eta' : '$name is on the way in $eta';
  String get tripCompletedTitle => _es ? 'Viaje completado' : 'Trip completed';
  String get arrivedAtDestination => _es
      ? 'Has llegado a tu destino.'
      : 'You have arrived at your destination.';
  String get tripStartedTitle => _es ? 'Viaje iniciado' : 'Trip started';
  String headingToDestination(String dest) =>
      _es ? 'Ahora te diriges a $dest' : 'You are now heading to $dest';
  String get driverArrivedTitle => _es ? 'Conductor llegó' : 'Driver arrived';
  String driverArrivedMessage(String name) => _es
      ? '$name ha llegado al punto de recogida.'
      : '$name has arrived at the pickup location.';
  String get loadingAddress =>
      _es ? 'Cargando dirección...' : 'Loading address...';

  // ── Terms & Conditions ──
  String get termsTitle =>
      _es ? 'Términos y Condiciones' : 'Terms & Conditions';
  String get termsLastUpdated => _es ? 'Última actualización' : 'Last Updated';
  String get termsLastUpdatedDate =>
      _es ? '27 de febrero de 2026' : 'February 27, 2026';
  String get termsAcceptanceTitle =>
      _es ? '1. Aceptación de los Términos' : '1. Acceptance of Terms';
  String get termsAcceptanceBody => _es
      ? 'Al descargar, acceder o usar la aplicación Cruise ("App"), usted acepta estar sujeto a estos Términos y Condiciones ("Términos"). Si no está de acuerdo con estos Términos, por favor no use la App. Estos Términos constituyen un acuerdo legalmente vinculante entre usted y Royal Purple LLC ("Cruise", "nosotros" o "nuestro").'
      : 'By downloading, accessing, or using the Cruise application ("App"), you agree to be bound by these Terms and Conditions ("Terms"). If you do not agree to these Terms, please do not use the App. These Terms constitute a legally binding agreement between you and Royal Purple LLC ("Cruise," "we," or "our").';
  String get termsEligibilityTitle =>
      _es ? '2. Elegibilidad' : '2. Eligibility';
  String get termsEligibilityBody => _es
      ? 'Debe tener al menos 18 años para crear una cuenta y usar los servicios de Cruise. Al usar la App, usted declara y garantiza que cumple con este requisito de edad y tiene la capacidad legal para aceptar estos Términos.'
      : 'You must be at least 18 years old to create an account and use Cruise services. By using the App, you represent and warrant that you meet this age requirement and have the legal capacity to enter into these Terms.';
  String get termsAccountTitle =>
      _es ? '3. Registro de Cuenta' : '3. Account Registration';
  String get termsAccountBody => _es
      ? 'Para acceder a ciertas funciones, debe registrarse y crear una cuenta. Usted acepta:\n\n• Proporcionar información precisa, actual y completa durante el registro\n• Mantener la seguridad de su contraseña y cuenta\n• Notificarnos inmediatamente de cualquier uso no autorizado\n• Aceptar responsabilidad por toda actividad bajo su cuenta\n\nNos reservamos el derecho de suspender o terminar cuentas que violen estos Términos.'
      : 'To access certain features, you must register and create an account. You agree to:\n\n• Provide accurate, current, and complete registration information\n• Maintain the security of your password and account\n• Notify us immediately of any unauthorized use\n• Accept responsibility for all activity under your account\n\nWe reserve the right to suspend or terminate accounts that violate these Terms.';
  String get termsServicesTitle =>
      _es ? '4. Descripción de Servicios' : '4. Services Description';
  String get termsServicesBody => _es
      ? 'Cruise proporciona una plataforma tecnológica que conecta pasajeros con proveedores de transporte independientes ("Conductores"). Somos una empresa de servicios tecnológicos y no proporcionamos servicios de transporte. Todos los viajes son realizados por Conductores independientes que no son empleados de Cruise.'
      : 'Cruise provides a technology platform that connects riders with independent transportation providers ("Drivers"). We are a technology services company and do not provide transportation services. All rides are performed by independent Drivers who are not employees of Cruise.';
  String get termsBookingTitle => _es
      ? '5. Reserva y Cancelación de Viajes'
      : '5. Ride Booking & Cancellation';
  String get termsBookingBody => _es
      ? 'Al solicitar un viaje a través de la App:\n\n• Se le proporcionará una tarifa estimada antes de confirmar\n• Los precios pueden variar según la demanda, distancia y condiciones del tráfico\n• Puede cancelar en la app en cualquier momento antes de que el viaje inicie\n• Cancelación gratuita: en cualquier momento antes de que se asigne un conductor, y dentro de los 2 minutos posteriores a la asignación del conductor\n• Tarifa de cancelación: \$5.00 después de la ventana gratuita, si el conductor está en camino o ha llegado al punto de recogida\n• Cargos por tiempo de espera tras el período gratuito: Standard/Compact 2 min gratis, luego \$0.40 por minuto; Premium 3 min gratis, luego \$0.60 por minuto; Black/SUV XL 5 min gratis, luego \$1.00 por minuto; viajes de aeropuerto (hacia o desde el aeropuerto) 10 min gratis, luego \$0.40 por minuto; los minutos parciales se redondean hacia arriba\n• Si no se presenta, el viaje puede cancelarse y se aplican los cargos de espera acumulados'
      : 'When you request a ride through the App:\n\n• You will be provided with an estimated fare before confirming\n• Prices may vary based on demand, distance, and traffic conditions\n• You may cancel in the app at any time before the trip starts\n• Free cancellation: any time before a driver is assigned, and within 2 minutes after driver assignment\n• Cancellation fee: \$5.00 after the free window, if the driver is en route to or has arrived at the pickup location\n• Wait-time charges after the free period: Standard/Compact 2 free min, then \$0.40 per minute; Premium 3 free min, then \$0.60 per minute; Black/SUV XL 5 free min, then \$1.00 per minute; Airport trips (to or from the airport) 10 free min, then \$0.40 per minute; partial minutes round up\n• If you do not show up, the trip may be canceled and the accrued wait-time charges apply';
  String get termsPaymentsTitle =>
      _es ? '6. Pagos y Precios' : '6. Payments & Pricing';
  String get termsPaymentsBody => _es
      ? 'Al usar Cruise, usted acepta pagar todas las tarifas incurridas:\n\n• Tarifa base + tarifa por distancia + tarifa por tiempo\n• Recargo por hora pico durante períodos de alta demanda\n• Peajes, tarifas de aeropuerto y otros cargos aplicables\n• Todos los precios están en Dólares Estadounidenses (USD)\n• Los recibos se envían por correo electrónico después de cada viaje\n• Las disputas deben presentarse dentro de los 30 días'
      : 'By using Cruise, you agree to pay all fares incurred:\n\n• Base fare + per-mile rate + per-minute rate\n• Surge pricing during high-demand periods\n• Tolls, airport fees, and other applicable charges\n• All prices are in US Dollars (USD)\n• Receipts are emailed after each trip\n• Disputes must be filed within 30 days';
  String get termsPaymentMethodsTitle =>
      _es ? '7. Métodos de Pago' : '7. Payment Methods';
  String get termsPaymentMethodsBody => _es
      ? 'Cruise acepta los siguientes métodos de pago:\n\n• Tarjetas de crédito y débito (Visa, Mastercard, Amex, Discover)\n• Google Pay\n• PayPal\n• Cruise Cash (créditos en la app)\n\nAl agregar un método de pago, usted autoriza a Cruise a cobrar el método de pago seleccionado por las tarifas de viaje. Debe mantener al menos un método de pago válido en su cuenta para solicitar viajes.'
      : 'Cruise accepts the following payment methods:\n\n• Credit and debit cards (Visa, Mastercard, Amex, Discover)\n• Google Pay\n• PayPal\n• Cruise Cash (in-app credits)\n\nBy adding a payment method, you authorize Cruise to charge your selected payment method for ride fares. You must maintain at least one valid payment method on your account to request rides.';
  String get termsUserConductTitle =>
      _es ? '8. Conducta del Usuario' : '8. User Conduct';
  String get termsUserConductBody => _es
      ? 'Al usar la App y durante los viajes, usted acepta:\n\n• Tratar a los conductores con respeto y cortesía\n• No dañar ni ensuciar vehículos\n• Cumplir con todas las leyes y regulaciones aplicables\n• No usar el servicio para actividades ilegales\n• No transportar sustancias ilegales o armas\n• Usar cinturón de seguridad durante todos los viajes'
      : 'While using the App and during rides, you agree to:\n\n• Treat drivers with respect and courtesy\n• Not damage or soil vehicles\n• Comply with all applicable laws and regulations\n• Not use the service for illegal activities\n• Not transport illegal substances or weapons\n• Wear a seatbelt during all rides';
  String get termsSafetyTitle => _es ? '9. Seguridad' : '9. Safety';
  String get termsSafetyBody => _es
      ? 'Su seguridad es nuestra prioridad. Cruise implementa las siguientes medidas:\n\n• Todos los conductores pasan verificaciones de antecedentes\n• Seguimiento GPS en tiempo real durante los viajes\n• Botón de emergencia en la app con integración al 911\n• Compartir viaje con contactos de confianza\n• Verificación de identidad del conductor antes de cada viaje\n• Cobertura de seguro durante viajes activos\n\nSi se siente inseguro durante un viaje, puede contactar servicios de emergencia directamente a través de la app.'
      : 'Your safety is our priority. Cruise implements the following measures:\n\n• All drivers undergo background checks\n• Real-time GPS tracking during rides\n• In-app emergency button with 911 integration\n• Share your ride with trusted contacts\n• Driver identity verification before each ride\n• Insurance coverage during active rides\n\nIf you feel unsafe during a ride, you can contact emergency services directly through the app.';
  String get termsPrivacyTitle => _es ? '10. Privacidad' : '10. Privacy';
  String get termsPrivacyBody => _es
      ? 'Su privacidad es importante para nosotros. Nuestra Política de Privacidad, incorporada a estos Términos por referencia, describe cómo recopilamos, usamos y protegemos su información personal. Al usar la App, usted consiente a la recopilación y uso de datos como se describe en nuestra Política de Privacidad.'
      : 'Your privacy is important to us. Our Privacy Policy, incorporated into these Terms by reference, describes how we collect, use, and protect your personal information. By using the App, you consent to the collection and use of data as described in our Privacy Policy.';
  String get termsIpTitle =>
      _es ? '11. Propiedad Intelectual' : '11. Intellectual Property';
  String get termsIpBody => _es
      ? 'El nombre, logotipo, diseño de la app y todo el contenido relacionado de Cruise son propiedad de Royal Purple LLC y están protegidos por leyes de propiedad intelectual. No puede copiar, modificar, distribuir ni crear trabajos derivados sin nuestro consentimiento previo por escrito.'
      : 'The Cruise name, logo, app design, and all related content are the property of Royal Purple LLC and are protected by intellectual property laws. You may not copy, modify, distribute, or create derivative works without our prior written consent.';
  String get termsLiabilityTitle =>
      _es ? '12. Limitación de Responsabilidad' : '12. Limitation of Liability';
  String get termsLiabilityBody => _es
      ? 'En la máxima medida permitida por la ley:\n\n• Cruise no se hace responsable de daños indirectos, incidentales, especiales o consecuentes\n• Nuestra responsabilidad total está limitada al monto que pagó por el servicio\n• No garantizamos disponibilidad ininterrumpida del servicio\n• No somos responsables de las acciones u omisiones de los conductores independientes\n• Usted usa el servicio bajo su propio riesgo'
      : 'To the maximum extent permitted by law:\n\n• Cruise is not liable for indirect, incidental, special, or consequential damages\n• Our total liability is limited to the amount you paid for the service\n• We do not guarantee uninterrupted service availability\n• We are not responsible for the actions or omissions of independent Drivers\n• You use the service at your own risk';
  String get termsIndemnificationTitle =>
      _es ? '13. Indemnización' : '13. Indemnification';
  String get termsIndemnificationBody => _es
      ? 'Usted acepta indemnizar, defender y mantener indemne a Cruise y sus funcionarios, directores, empleados y agentes de cualquier reclamo, daño, pérdida o gasto (incluyendo honorarios legales razonables) que surja de su uso de la App o violación de estos Términos.'
      : 'You agree to indemnify, defend, and hold harmless Cruise and its officers, directors, employees, and agents from any claims, damages, losses, or expenses (including reasonable legal fees) arising from your use of the App or violation of these Terms.';
  String get termsTerminationTitle =>
      _es ? '14. Terminación' : '14. Termination';
  String get termsTerminationBody => _es
      ? 'Nos reservamos el derecho de suspender o terminar su cuenta en cualquier momento, con o sin causa, incluyendo pero no limitado a violaciones de estos Términos. Tras la terminación, se le prohibirá el acceso a los servicios y cualquier saldo restante puede ser confiscado según las circunstancias.'
      : 'We reserve the right to suspend or terminate your account at any time, with or without cause, including but not limited to violations of these Terms. Upon termination, you will be prohibited from accessing the services and any remaining balance may be forfeited depending on the circumstances.';
  String get termsDisputeTitle =>
      _es ? '15. Resolución de Disputas' : '15. Dispute Resolution';
  String get termsDisputeBody => _es
      ? 'Cualquier disputa que surja de estos Términos o se relacione con ellos se resolverá mediante arbitraje individual vinculante administrado por la Asociación Americana de Arbitraje (AAA), con sede en el Condado de Miami-Dade, Florida, conforme a la ley de Florida. Las reclamaciones solo pueden presentarse a título individual: se renuncia a cualquier acción colectiva, consolidada o representativa, incluidas las acciones de fiscal general privado, y ambas partes renuncian a cualquier derecho a un juicio con jurado. Cualquiera de las partes puede presentar una reclamación individual ante el tribunal de reclamos menores (small claims) del Condado de Miami-Dade, Florida. Puede optar por no participar en el arbitraje enviando un correo a support@cruiseapp.com dentro de los 30 días siguientes a la primera aceptación de estos Términos; si opta por salir, las disputas se litigarán en los tribunales del Condado de Miami-Dade, Florida, y la renuncia a acciones colectivas se mantiene donde la ley lo permita. Este arbitraje no aplica al proceso de disputa y acción preadversa bajo la FCRA.'
      : 'Any dispute arising from or relating to these Terms will be resolved by binding individual arbitration administered by the American Arbitration Association (AAA), seated in Miami-Dade County, Florida, under Florida law. Claims may be brought only in an individual capacity: class, collective, consolidated, and representative actions — including private attorney general actions — are waived, and both parties waive any right to a jury trial. Either party may bring an individual claim in the small-claims court of Miami-Dade County, Florida. You may opt out of arbitration by emailing support@cruiseapp.com within 30 days of first accepting these Terms; if you opt out, disputes are litigated in the courts of Miami-Dade County, Florida, and the class action waiver survives opt-out where permitted by law. This arbitration agreement does not apply to the FCRA pre-adverse action and dispute process.';
  String get termsModificationsTitle =>
      _es ? '16. Modificaciones' : '16. Modifications';
  String get termsModificationsBody => _es
      ? 'Cruise se reserva el derecho de modificar estos Términos en cualquier momento. Los cambios entrarán en vigencia al ser publicados en la App. El uso continuado después de los cambios constituye la aceptación de los Términos modificados. Las modificaciones materiales serán notificadas por correo electrónico o notificación en la app.'
      : 'Cruise reserves the right to modify these Terms at any time. Changes will be effective upon posting to the App. Continued use after changes constitutes acceptance of the modified Terms. Material changes will be notified via email or in-app notification.';
  String get termsGoverningLawTitle =>
      _es ? '17. Ley Aplicable' : '17. Governing Law';
  String get termsGoverningLawBody => _es
      ? 'Estos Términos se regirán exclusivamente por las leyes del Estado de Florida, sin tener en cuenta los principios de conflicto de leyes. Sujeto al acuerdo de arbitraje de la sección de Resolución de Disputas, cualquier reclamación que se litigue ante un tribunal se presentará ante los tribunales estatales o federales ubicados en el Condado de Miami-Dade, Florida, y las partes consienten la jurisdicción personal y la competencia de dichos tribunales.'
      : 'These Terms are governed exclusively by the laws of the State of Florida, without regard to conflict-of-laws principles. Subject to the arbitration agreement in the Dispute Resolution section, any claim that proceeds in court shall be brought in the state or federal courts located in Miami-Dade County, Florida, and the parties consent to the personal jurisdiction and venue of those courts.';
  String get termsContactTitle => _es ? '18. Contáctenos' : '18. Contact Us';
  String get termsContactBody => _es
      ? 'Si tiene alguna pregunta sobre estos Términos, contáctenos:\n\nRoyal Purple LLC\nEmail: legal@cruiseapp.com\nSoporte: support@cruiseapp.com'
      : 'If you have any questions about these Terms, please contact us:\n\nRoyal Purple LLC\nEmail: legal@cruiseapp.com\nSupport: support@cruiseapp.com';
  String get termsAcceptanceNotice => _es
      ? 'Al crear una cuenta o usar la app Cruise, usted reconoce que ha leído, comprendido y acepta estar sujeto a estos Términos y Condiciones.'
      : 'By creating an account or using the Cruise app, you acknowledge that you have read, understood, and agree to be bound by these Terms and Conditions.';

  // ── Rider Home Screen ──
  String get rideInProgress => _es ? 'Viaje en progreso' : 'Ride in progress';
  String promoLockedProgress(int completed) => _es
      ? '$completed / 3 viajes completados'
      : '$completed / 3 rides completed';
  String get promoWelcomeBody => _es
      ? 'Como bienvenida a Cruise, ¡disfruta un 10% de descuento en tu primer viaje! Esta oferta exclusiva solo puede usarse una vez y se aplicará automáticamente a tu próximo viaje.'
      : 'As a welcome to Cruise, enjoy 10% off your first ride! This exclusive offer can only be used once and will be applied automatically to your next ride.';
  String get searchHomeAddress =>
      _es ? 'Buscar tu dirección de casa' : 'Search your home address';
  String get searchWorkAddress =>
      _es ? 'Buscar tu dirección de trabajo' : 'Search your work address';
  String get savePlace1 => _es ? 'Guardar lugar 1' : 'Save Place 1';
  String get editPlace1 => _es ? 'Editar lugar 1' : 'Edit Place 1';
  String get savePlace2 => _es ? 'Guardar lugar 2' : 'Save Place 2';
  String get editPlace2 => _es ? 'Editar lugar 2' : 'Edit Place 2';
  String get searchAnAddress =>
      _es ? 'Buscar una dirección' : 'Search an address';
  String get notificationsTitle => _es ? 'Notificaciones' : 'Notifications';
  String get driverLabel => _es ? 'Conductor' : 'Driver';
  String get minSuffix => _es ? 'min' : 'min';
  // Fleet descriptions
  String get vipDesc => _es
      ? 'SUV de lujo con comodidades premium'
      : 'Luxury SUV with premium amenities';
  String get suvXlDesc => _es
      ? 'SUV grande para grupos y equipaje'
      : 'Full-size SUV for groups and luggage';
  String get suvXlFeatures => _es
      ? 'Hasta 6 • Equipaje XL • Climatizado'
      : 'Up to 6 • XL luggage • Climate';
  String get vipFeatures => _es
      ? 'Espacioso • Cuero • Snacks y Bebidas'
      : 'Spacious • Leather • Snacks & Drinks';
  String get premiumDesc => _es
      ? 'Sedán elegante para cualquier ocasión'
      : 'Elegant sedan for any occasion';
  String get premiumFeatures =>
      _es ? 'Confort • Clima • Cargador' : 'Comfort • Climate • Charger';
  String get comfortDesc =>
      _es ? 'Viaje confiable al mejor precio' : 'Reliable ride at great value';
  String get comfortFeatures =>
      _es ? 'Limpio • Seguro • Eficiente' : 'Clean • Safe • Efficient';

  // ── Driver Home ──
  String get rider => _es ? 'Pasajero' : 'Rider';
  String get goodMorning => _es ? 'Buenos días' : 'Good morning';
  String get goodAfternoon => _es ? 'Buenas tardes' : 'Good afternoon';
  String get goodEvening => _es ? 'Buenas noches' : 'Good evening';

  // ── Driver Menu ──
  String get emailUs => _es ? 'Envíanos un correo' : 'Email Us';
  String get available247 => _es ? 'Disponible 24/7' : 'Available 24/7';
  String get faqLabel => _es ? 'Preguntas Frecuentes' : 'FAQ';
  String get commonQuestions => _es ? 'Preguntas comunes' : 'Common questions';
  String get signOutTitle => _es ? 'Cerrar sesión' : 'Sign Out';
  String get signOutConfirmation => _es
      ? '¿Estás seguro de que deseas cerrar sesión?'
      : 'Are you sure you want to sign out?';
  String get signOutButton => _es ? 'Cerrar sesión' : 'Sign Out';
  String get cruiseLevelTiers => _es
      ? 'Bronce → Plata → Oro → Platino → Diamante'
      : 'Bronze → Silver → Gold → Platinum → Diamond';

  // ── Driver Login ──
  String get accountIsRider => _es
      ? 'Esta cuenta está registrada como pasajero. Por favor usa el inicio de sesión de pasajero.'
      : 'This account is registered as a rider. Please use the rider login.';
  String get accountDeleted =>
      _es ? 'Esta cuenta ya no existe' : 'This account no longer exists';
  String get accountDeactivated2 => _es
      ? 'Tu cuenta ha sido desactivada'
      : 'Your account has been deactivated';
  String get driverBadge => _es ? 'Conductor' : 'Driver';
  String get welcomeBackDriver =>
      _es ? 'Bienvenido de nuevo,\nConductor' : 'Welcome back,\nDriver';
  String get signInToEarn => _es
      ? 'Inicia sesión para empezar a ganar con Cruise'
      : 'Sign in to start earning with Cruise';
  String get passwordLabel => _es ? 'Contraseña' : 'Password';
  String get orDivider => _es ? 'O' : 'OR';
  String get signUpToDrive =>
      _es ? 'Regístrate para conducir' : 'Sign up to drive';
  String get lookingToRide => _es ? '¿Buscas un viaje? ' : 'Looking to ride? ';
  String get switchToRider => _es ? 'Cambiar a pasajero' : 'Switch to rider';

  // ── Driver Signup ──
  String get photoNotClear => _es ? 'Foto no clara' : 'Photo Not Clear';
  String get imageQualityTooLow => _es
      ? 'La calidad de la imagen es demasiado baja. Por favor toma una foto clara y bien iluminada.'
      : 'Image quality is too low. Please take a clear, well-lit photo.';
  String get useCamera => _es ? 'Usar Cámara' : 'Use Camera';
  String stepOf(int step, int total) =>
      _es ? 'Paso $step de $total' : 'Step $step of $total';
  String photoOf(int photo, int total) =>
      _es ? 'Foto $photo de $total' : 'Photo $photo of $total';
  String get firstNameLabel => _es ? 'Nombre' : 'First name';
  String get lastNameLabel => _es ? 'Apellido' : 'Last name';
  String get emailAddressLabel => _es ? 'Correo electrónico' : 'Email address';
  String get phoneNumberLabel => _es ? 'Número de teléfono' : 'Phone number';
  String get vehicleMake => _es ? 'Marca' : 'Make';
  String get vehicleModel => _es ? 'Modelo' : 'Model';
  String get vehicleYear => _es ? 'Año' : 'Year';
  String get vehicleColor => _es ? 'Color' : 'Color';
  String get licensePlateLabel =>
      _es ? 'Número de placa' : 'License plate number';
  String get vehicleRequirements => _es
      ? 'El vehículo debe ser del 2010 o más nuevo, 4 puertas, y pasar una inspección vehicular.'
      : 'Vehicle must be 2010 or newer, 4-door, and pass a vehicle inspection.';
  String get completeAllItems => _es
      ? 'Complete todos los elementos para continuar'
      : 'Complete all items to continue';
  String get ssnLabel =>
      _es ? 'Número de Seguro Social' : 'Social Security Number';
  String get requiredBadge => _es ? 'Requerido' : 'Required';
  String get ssnEntered => _es ? 'SSN ingresado ✓' : 'SSN entered ✓';
  String get enterSsn => _es
      ? 'Ingresa tu Número de Seguro Social'
      : 'Enter your Social Security Number';
  String get ssnEncryptedNote => _es
      ? 'Tu SSN está encriptado y solo se usa para verificación de identidad.'
      : 'Your SSN is encrypted and only used for identity verification.';
  String get biometricFaceCheck =>
      _es ? 'Verificación Biométrica Facial' : 'Biometric Face Check';
  String get faceLivenessVerified =>
      _es ? 'Verificación facial completada ✓' : 'Face liveness verified ✓';
  String get biometricInstructions => _es
      ? 'Mira, gira, parpadea — toma ~15 segundos'
      : 'Look, turn, blink — takes ~15 seconds';
  String get licenseFrontLabel => _es ? 'Licencia Frente' : 'License Front';
  String get licenseBackLabel => _es ? 'Licencia Reverso' : 'License Back';
  String get ssnShortLabel => _es ? 'SSN' : 'SSN';
  String get faceCheckLabel => _es ? 'Verificación Facial' : 'Face Check';
  String get uploadedStatus => _es ? 'Subido ✓' : 'Uploaded ✓';
  String get missingStatus => _es ? 'Faltante' : 'Missing';
  String get providedStatus => _es ? 'Proporcionado ✓' : 'Provided ✓';
  String get notCompletedStatus => _es ? 'No completado' : 'Not completed';
  String get documentsComplete =>
      _es ? 'Documentos completos' : 'Documents complete';
  String get reviewAndSubmit => _es ? 'Revisar y Enviar' : 'Review & Submit';
  String get confirmBeforeSubmit => _es
      ? 'Confirma tus datos antes de enviar'
      : 'Confirm your details before submitting';
  String get nameLabel => _es ? 'Nombre' : 'Name';
  String get emailLabel => _es ? 'Correo' : 'Email';
  String get phoneLabel => _es ? 'Teléfono' : 'Phone';
  String get vehicleLabel => _es ? 'Vehículo' : 'Vehicle';
  String get plateLabel => _es ? 'Placa' : 'Plate';
  String get agreeTermsText => _es
      ? 'Acepto los Términos de Servicio para Conductores de Cruise, reconozco la Política de Privacidad y consiento a una verificación de antecedentes.'
      : "I agree to Cruise's Driver Terms of Service, acknowledge the Privacy Policy, and consent to a background check.";
  String get agreeContractorText => _es
      ? 'Acepto el Acuerdo de Contratista Independiente.'
      : 'I agree to the Independent Contractor Agreement.';
  String get agreementAcceptFailed => _es
      ? 'No se pudo registrar tu aceptación — revisa tu conexión e inténtalo de nuevo.'
      : 'Could not record your acceptance — check your connection and try again.';
  String get readContractorAgreement => _es
      ? 'Leer el Acuerdo de Contratista Independiente'
      : 'Read the Independent Contractor Agreement';
  String get agreeBackgroundCheckText => _es
      ? 'He leído y acepto el documento de Divulgación y Autorización de Verificación de Antecedentes (FCRA).'
      : 'I have read and agree to the Background Check Disclosure and Authorization (FCRA).';
  String get agreePrivacyPolicyText => _es
      ? 'He leído y acepto la Política de Privacidad y las políticas de la app y la compañía.'
      : 'I have read and agree to the Privacy Policy and the app and company policies.';
  String get readDriverTermsDoc =>
      _es ? 'Leer los Términos de Servicio' : 'Read the Terms of Service';
  String get readBackgroundCheckDoc => _es
      ? 'Leer el documento de verificación de antecedentes'
      : 'Read the background check document';
  String get readPrivacyPolicyDoc =>
      _es ? 'Leer la Política de Privacidad' : 'Read the Privacy Policy';
  String get readAllDocsCheckbox => _es
      ? 'He leído los siguientes documentos:'
      : 'I have read the following documents:';
  String get acceptAllDocsCheckbox => _es
      ? 'Acepto y estoy de acuerdo con los siguientes documentos:'
      : 'I accept and agree with the following documents:';
  String get acceptDocsAboveText => _es
      ? 'Acepto y estoy de acuerdo con los documentos anteriores.'
      : 'I accept and agree with the documents above.';
  String get readAcceptAllDocsText => _es
      ? 'He leído, acepto y estoy de acuerdo con los términos, condiciones y políticas.'
      : 'I have read, accept, and agree with the terms, conditions, and policies.';
  String get docLinkDriverTerms =>
      _es ? 'Términos de Servicio para Conductores' : 'Driver Terms of Service';
  String get docLinkBackgroundCheck => _es
      ? 'Divulgación y Autorización de Verificación de Antecedentes'
      : 'Background Check Disclosure & Authorization';
  String get docLinkPrivacyPolicy => _es
      ? 'Política de Privacidad y políticas de la compañía'
      : 'Privacy Policy & company policies';
  String get docLinkContractor => _es
      ? 'Acuerdo de Contratista Independiente'
      : 'Independent Contractor Agreement';
  String get driverTermsOfServiceMenu =>
      _es ? 'Términos de Servicio para Conductores' : 'Driver Terms of Service';
  String get driverTermsOfServiceMenuSubtitle =>
      _es ? 'Lee y acepta los términos' : 'Review and accept the terms';
  String get applicationReviewNote => _es
      ? 'Tu solicitud y verificación de antecedentes serán revisadas en 24-48 horas. Se te notificará por correo una vez aprobado.'
      : 'Your application and background check will be reviewed within 24-48 hours. You will be notified via email once approved.';

  // ── Driver Earnings ──
  String get tripsStatLabel => _es ? 'Viajes' : 'Trips';
  String get onlineStatLabel => _es ? 'En línea' : 'Online';
  String get tipsStatLabel => _es ? 'Propinas' : 'Tips';

  // ── Driver Trip History ──
  String get todayDatePrefix => _es ? 'Hoy' : 'Today';
  String get yesterdayDatePrefix => _es ? 'Ayer' : 'Yesterday';
  String get tripFallback => _es ? 'Viaje' : 'Trip';
  String get cancelledBadge => _es ? 'Cancelado' : 'Cancelled';
  String get tipSuffix => _es ? 'propina' : 'tip';
  String get tripDetails => _es ? 'Detalles del Viaje' : 'Trip Details';
  String get cancelledTrip => _es ? 'Viaje Cancelado' : 'Cancelled Trip';
  String get pickupUpperLabel => _es ? 'RECOGIDA' : 'PICKUP';
  String get dropoffUpperLabel => _es ? 'DESTINO' : 'DROPOFF';
  String get fareLabel => _es ? 'Tarifa' : 'Fare';
  String get distanceLabel => _es ? 'Distancia' : 'Distance';
  String get durationLabel => _es ? 'Duración' : 'Duration';
  String get tipLabel => _es ? 'Propina' : 'Tip';

  // ── Driver Pending Review ──
  String get applicationNotApproved => _es
      ? 'Tu solicitud no fue aprobada en este momento.'
      : 'Your application was not approved at this time.';
  String get applicationSubmittedDone =>
      _es ? 'Solicitud enviada' : 'Application submitted';
  String get allDocsReceivedDone =>
      _es ? 'Todos los documentos recibidos' : 'All documents received';
  String get backgroundCheckDone =>
      _es ? 'Verificación de antecedentes' : 'Background check';
  String get identityVerifiedDone =>
      _es ? 'Identidad verificada ✓' : 'Identity verified ✓';
  String get finalReviewDone => _es ? 'Revisión final' : 'Final review';
  String get approvedByDispatch =>
      _es ? 'Aprobado por despacho ✓' : 'Approved by dispatch ✓';
  String get applicationRejected =>
      _es ? 'Verificación Rechazada' : 'Verification Rejected';
  String get rejectionDescription => _es
      ? 'Tu verificación fue rechazada. Por favor intenta de nuevo y revisa cada requisito cuidadosamente para que coincida con tu información.'
      : 'Your verification was rejected. Please try again and review each requirement carefully so it matches your information.';
  String get backToWelcome => _es ? 'Volver al Inicio' : 'Back to Welcome';

  // ── License Scanner ──
  String get alignLicenseInstruction => _es
      ? 'Alinea tu licencia dentro del marco y presiona el botón para escanear'
      : 'Align your license within the frame and tap the button to scan';
  String get noDocumentDetected => _es
      ? 'No se detectó un documento válido. Intenta de nuevo con mejor iluminación.'
      : 'No valid document detected. Try again with better lighting.';

  // ── Payout Methods ──
  String get plaidLinkDescription => _es
      ? 'Recibe tus pagos semanales directo a tu cuenta. Los pagos se procesan cada martes.'
      : 'Receive your weekly earnings directly to your account. Payments are processed every Tuesday.';
  String get connectingLabel => _es ? 'Conectando...' : 'Connecting...';
  String get connectBankForCashouts => _es
      ? 'Agrega una cuenta bancaria para recibir\ntus ganancias cada semana'
      : 'Add a bank account to receive\nyour weekly earnings';
  String get defaultBadge => _es ? 'Predeterminado' : 'Default';
  String get bankTransferType =>
      _es ? 'Transferencia bancaria' : 'Bank transfer';
  String get checkingAccount => _es ? 'Corriente' : 'Checking';
  String get savingsAccount => _es ? 'Ahorros' : 'Savings';
  String get bankNameLabel => _es ? 'Nombre del banco' : 'Bank name';
  String get routingNumberLabel => _es ? 'Número de ruta' : 'Routing number';
  String get accountNumberLabel => _es ? 'Número de cuenta' : 'Account number';
  String get infoEncryptedSecure => _es
      ? 'Tu información está encriptada y segura'
      : 'Your information is encrypted and secure';
  String get linkAccountButton => _es ? 'Vincular cuenta' : 'Link account';
  String get addDebitCardTitle =>
      _es ? 'Agregar tarjeta de débito' : 'Add debit card';
  String get addDebitForCashouts => _es
      ? 'Agrega tu tarjeta de débito para retiros instantáneos.'
      : 'Add your debit card for instant cashouts.';
  String get cardNumberLabel => _es ? 'Número de tarjeta' : 'Card number';
  String get cardholderNameLabel =>
      _es ? 'Nombre del titular' : 'Cardholder name';
  String get addCardButton => _es ? 'Agregar tarjeta' : 'Add card';
  String get removeLabel => _es ? 'Eliminar' : 'Remove';
  String get payoutMethodRemoved =>
      _es ? 'Método de pago eliminado' : 'Payout method removed';
  String get failedToRemoveMethod =>
      _es ? 'Error al eliminar método' : 'Failed to remove method';

  // ── Schedule validation ────────────────────────────────────────────────────
  String get scheduleTooSoon => _es
      ? 'Selecciona un horario con al menos 30 minutos de anticipación.'
      : 'Please select a time at least 30 minutes from now.';

  // ── Account Deletion ──────────────────────────────────────────────────────
  String get deleteAccountProcessing => _es
      ? 'Tu cuenta será procesada y eliminada junto con toda tu información en un lapso de 1 semana.'
      : 'Your account will be processed and deleted along with all your information within 1 week.';
  String get deleteAccountQuestion => _es
      ? '¿Estás seguro de que quieres eliminar tu cuenta?'
      : 'Are you sure you want to delete your account?';
  String get sure => _es ? 'Seguro' : 'Sure';
  String get cancelDeletion => _es ? 'Cancelar eliminación' : 'Cancel Deletion';

  // ── Manage Account ──
  String get photoUpdated => _es ? 'Foto actualizada' : 'Photo updated';
  String get maxChangesReached =>
      _es ? 'Máximo de cambios alcanzado (3)' : 'Maximum changes reached (3)';
  String get emailUpdated => _es ? 'Correo actualizado' : 'Email updated';
  String get phoneUpdated => _es ? 'Teléfono actualizado' : 'Phone updated';
  String get nameCannotBeChanged =>
      _es ? 'El nombre no se puede cambiar' : 'Name cannot be changed';
  String get locked => _es ? 'Bloqueado' : 'Locked';
  String get changesSaved => _es ? 'Cambios guardados' : 'Changes saved';

  // ── Ride offer card ──
  String get plusTips => _es ? '+ Propinas' : '+ Tips';
  String offerHourlyRate(String amount) => _es
      ? '\$$amount/h estimado por este viaje'
      : '\$$amount/hr est. rate for this ride';

  /// The same figure as [offerHourlyRate] with the sentence stripped, for
  /// the Dynamic Island, where the full phrase has nowhere to go.
  String offerHourlyRateShort(String amount) =>
      _es ? '\$$amount/h' : '\$$amount/hr';

  /// Minutes, but hours once there are 60 of them. "78 min" is a number
  /// the driver has to divide in their head while a car is waiting.
  String offerDuration(int minutes) {
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '$h h' : '$h h $m min';
  }

  String offerAway(int minutes, String miles) => _es
      ? '${offerDuration(minutes)} ($miles mi) de distancia'
      : '${offerDuration(minutes)} ($miles mi) away';
  String offerTrip(int minutes, String miles) => _es
      ? '${offerDuration(minutes)} ($miles mi) de viaje'
      : '${offerDuration(minutes)} ($miles mi) trip';
  String get changesUsed => _es ? 'cambios usados' : 'changes used';
  String get errorOccurred => _es ? 'Ocurrió un error' : 'An error occurred';
  String get deleteAccountTitle => _es ? 'Eliminar Cuenta' : 'Delete Account';
  String get deleteAccountMsg => _es
      ? 'Tu cuenta será procesada y eliminada junto con toda tu información en un lapso de 1 semana. ¿Estás seguro?'
      : 'Your account will be processed and deleted along with all your information within 1 week. Are you sure?';
  String get sureButton => _es ? 'Seguro' : 'Sure';

  // ── Edit Address ──
  String get homeAddress => _es ? 'Dirección de casa' : 'Home Address';
  String get workAddress => _es ? 'Dirección de trabajo' : 'Work Address';
  String get enterHomeAddress =>
      _es ? 'Ingresa tu dirección de casa' : 'Enter your home address';
  String get enterWorkAddress =>
      _es ? 'Ingresa tu dirección de trabajo' : 'Enter your work address';
  String get addressSaved => _es ? 'Dirección guardada' : 'Address saved';

  // ── Siri Shortcuts ──
  String get siriGoOnlineDesc => _es
      ? '"Hey Siri, ponme en línea en Cruise"'
      : '"Hey Siri, go online on Cruise"';
  String get siriGoOfflineDesc => _es
      ? '"Hey Siri, desconéctame de Cruise"'
      : '"Hey Siri, go offline on Cruise"';
  String get checkEarnings => _es ? 'Ver Ganancias' : 'Check Earnings';
  String get siriCheckEarningsDesc => _es
      ? '"Hey Siri, ¿cuánto gané hoy?"'
      : '"Hey Siri, how much did I earn today?"';
  String get navigateHome => _es ? 'Navegar a Casa' : 'Navigate Home';
  String get siriNavigateHomeDesc =>
      _es ? '"Hey Siri, llévame a casa"' : '"Hey Siri, take me home"';
  String get siriShortcutsInfo => _es
      ? 'Configura comandos de voz personalizados para acciones rápidas mientras conduces.'
      : 'Set up custom voice commands for quick actions while driving.';

  // ── Communication ──
  String get pushNotificationsDesc => _es
      ? 'Recibir alertas de viaje en tiempo real'
      : 'Receive real-time trip alerts';
  String get emailNotifications =>
      _es ? 'Notificaciones por Correo' : 'Email Notifications';
  String get emailNotificationsDesc => _es
      ? 'Resúmenes y actualizaciones por correo'
      : 'Summaries and updates via email';
  String get smsNotifications =>
      _es ? 'Notificaciones SMS' : 'SMS Notifications';
  String get smsNotificationsDesc =>
      _es ? 'Alertas de texto importantes' : 'Important text alerts';
  String get promotionsDesc2 =>
      _es ? 'Ofertas y bonos especiales' : 'Special offers and bonuses';

  // ── Navigation ──
  String get defaultMapApp =>
      _es ? 'Aplicación de mapa predeterminada' : 'Default Map App';
  String get routePreferences =>
      _es ? 'Preferencias de ruta' : 'Route Preferences';
  String get avoidTolls => _es ? 'Evitar peajes' : 'Avoid Tolls';
  String get avoidHighways => _es ? 'Evitar autopistas' : 'Avoid Highways';

  // ── Sounds & Voice ──
  String get volumeLevel => _es ? 'Nivel de volumen' : 'Volume Level';
  String get tripRequestSounds =>
      _es ? 'Sonidos de solicitud de viaje' : 'Trip Request Sounds';
  String get tripRequestSoundsDesc => _es
      ? 'Alerta cuando llega un viaje nuevo'
      : 'Alert when a new trip arrives';
  String get navigationVoice => _es ? 'Voz de navegación' : 'Navigation Voice';
  String get navigationVoiceDesc => _es
      ? 'Indicaciones por voz paso a paso'
      : 'Step-by-step voice directions';
  String get messageSounds => _es ? 'Sonidos de mensajes' : 'Message Sounds';
  String get messageSoundsDesc => _es
      ? 'Alertas de chat y mensajes de pasajeros'
      : 'Chat and passenger message alerts';

  // ── Earnings ──
  String get totalEarnings => _es ? 'Ganancias Totales' : 'Total Earnings';
  String get onlineHours => _es ? 'Horas en línea' : 'Online Hours';
  String get tipsLabel => _es ? 'Propinas' : 'Tips';
  String get earningsChart => _es ? 'Gráfico de Ganancias' : 'Earnings Chart';
  String get recentTransactions =>
      _es ? 'Transacciones Recientes' : 'Recent Transactions';
  String get noEarningsYet => _es ? 'Aún no hay ganancias' : 'No earnings yet';

  // ── Support Chat ──
  String get endChat => _es ? 'Finalizar Chat' : 'End Chat';
  String get chatEnded => _es ? 'Chat finalizado' : 'Chat ended';
  String get endChatConfirm => _es
      ? '¿Estás seguro de que deseas finalizar este chat?'
      : 'Are you sure you want to end this chat?';
  String get chatClosed => _es ? 'Chat cerrado' : 'Chat closed';
  String get supervisorConnected =>
      _es ? 'Supervisor conectado' : 'Supervisor connected';
  String get automatedSystem =>
      _es ? 'Sistema automatizado' : 'Automated system';
  String get processingRequest =>
      _es ? 'Procesando solicitud...' : 'Processing request...';
  String get describeYourProblem =>
      _es ? 'Describe tu problema...' : 'Describe your issue...';
  String get writeToStart =>
      _es ? 'Escribe tu mensaje para iniciar' : 'Write your message to start';
  String get thisChatClosed =>
      _es ? 'Este chat ha sido cerrado.' : 'This chat has been closed.';
  String get startNewChat => _es ? 'Iniciar nuevo chat' : 'Start new chat';
  String get supportLineUnavailable => _es
      ? 'Línea de soporte no disponible en este momento'
      : 'Support line not available at this time';

  // ── Document type picker ──
  String get selectDocumentType =>
      _es ? 'Selecciona tipo de documento' : 'Select Document Type';
  String get chooseDocToScan => _es
      ? 'Elige qué documento quieres escanear'
      : 'Choose which document to scan';
  String get driversLicense =>
      _es ? 'Licencia de conducir' : "Driver's License";
  String get governmentId => _es ? 'Identificación oficial' : 'Government ID';
  String get passport => _es ? 'Pasaporte' : 'Passport';
  String get frontAndBack => _es ? 'Frente y dorso' : 'Front & Back';
  String get frontOnly => _es ? 'Solo frente' : 'Front Only';

  // ── Document photo guidelines ──
  String get guidelinesLicenseTitle => _es
      ? 'Pautas para tomar la foto de tu licencia de conducir'
      : "Guidelines for taking a photo of your driver's license";
  String get guidelinesGovIdTitle => _es
      ? 'Pautas para tomar la foto de tu identificación oficial'
      : 'Guidelines for taking a photo of your government ID';
  String get guidelinesPassportTitle => _es
      ? 'Pautas para tomar la foto de tu pasaporte'
      : 'Guidelines for taking a photo of your passport';

  String get guidelineLicenseValid => _es
      ? 'Asegúrate de que tu licencia esté vigente y sea válida'
      : 'Make sure your license is current and valid';
  String get guidelineLicensePhysical => _es
      ? 'La imagen que subas debe ser de tu licencia física'
      : 'The image you upload must be of your physical license';
  String get guidelineLicenseCorners => _es
      ? 'Asegúrate de que la foto salga nítida, que no esté borrosa, y que se vean las cuatro esquinas de tu licencia para evitar pasos de verificación adicionales'
      : 'Ensure the photo is clear, not blurry and includes all four corners of your license to avoid additional verification steps';

  String get guidelineGovIdValid => _es
      ? 'Asegúrate de que tu identificación oficial esté vigente y sea válida'
      : 'Make sure your government ID is current and valid';
  String get guidelineGovIdPhysical => _es
      ? 'La imagen que subas debe ser de tu identificación física'
      : 'The image you upload must be of your physical ID';
  String get guidelineGovIdCorners => _es
      ? 'Asegúrate de que la foto salga nítida, que no esté borrosa, y que se vean las cuatro esquinas de tu identificación para evitar pasos de verificación adicionales'
      : 'Ensure the photo is clear, not blurry and includes all four corners of your ID to avoid additional verification steps';

  String get guidelinePassportValid => _es
      ? 'Asegúrate de que tu pasaporte no esté vencido'
      : 'Make sure your passport has not expired and is still valid';
  String get guidelinePassportPhysical => _es
      ? 'La imagen que subas debe ser de tu pasaporte físico'
      : 'The image you upload must be of your physical passport';
  String get guidelinePassportCorners => _es
      ? 'Asegúrate de que la foto salga nítida, que no esté borrosa, y que se vean las cuatro esquinas de la página de datos para evitar pasos de verificación adicionales'
      : 'Ensure the photo is clear, not blurry and includes all four corners of the photo page to avoid additional verification steps';

  // ── Verification steps ──
  String get scanYourDocument =>
      _es ? 'Escanea tu documento' : 'Scan Your Document';
  String get quickDispatchReview => _es ? 'Revisión rápida' : 'Quick Review';
  String get documentsEncrypted => _es
      ? 'Tus documentos están encriptados y almacenados de forma segura'
      : 'Your documents are encrypted and securely stored';

  // ── License scanner extras ──
  String get scanDocument => _es ? 'Escanear documento' : 'Scan Document';
  String get scanPassport => _es ? 'Escanear pasaporte' : 'Scan Passport';
  String get scanId => _es ? 'Escanear identificación' : 'Scan ID';
  String get alignDocumentInstruction => _es
      ? 'Alinea tu documento dentro del marco'
      : 'Align your document within the frame';
  String get documentDetectedTakePhoto => _es
      ? '✓ Documento detectado — presiona el botón para capturar'
      : '✓ Document detected — tap the button to capture';
  String get autoCapturing =>
      _es ? 'Capturando automáticamente...' : 'Auto-capturing...';

  // ── Face liveness extras ──
  String get holdStill => _es ? 'Mantente quieto' : 'Hold Still';
  String get keepFaceCentered =>
      _es ? 'Mantén tu rostro centrado' : 'Keep your face centered';
  String get positionFaceInFrame => _es
      ? 'Sitúa tu cara\ndentro del marco.'
      : 'Position your face\nwithin the frame.';
  String get moveHeadSlowly => _es
      ? 'Mueve lentamente tu cabeza\npara cerrar el círculo.'
      : 'Move your head slowly\nto complete the circle.';
  String get startOver => _es ? 'Volver a empezar' : 'Start Over';
  String get faceVerified => _es ? 'Verificado' : 'Verified';

  // ── Driver Navigation Page ──
  String get estFare => _es ? 'Tarifa est.' : 'Est. fare';

  String get arrivedAtDest =>
      _es ? 'Llegaste al destino' : 'Arrived at destination';
  String get endTrip => _es ? 'FINALIZAR VIAJE' : 'END TRIP';
  String get finishRide => _es ? 'TERMINAR VIAJE' : 'FINISH RIDE';
  String get goHomeLabel => _es ? 'Ir a inicio' : 'Go Home';
  String get muteLabel => _es ? 'Silenciar' : 'Mute';
  String get unmuteLabel => _es ? 'Activar sonido' : 'Unmute';
  String get reportIncident => _es ? 'Reportar incidente' : 'Report incident';
  String get incidentReported =>
      _es ? 'Incidente reportado' : 'Incident reported';
  String get arrivalLabel => _es ? 'llegada' : 'arrival';
  String get remainingLabel => _es ? 'restante' : 'remaining';
  String get resumeNav => _es ? 'Reanudar' : 'Resume';

  /// Tracking map: puts the whole remaining route back on screen after the
  /// rider has panned or pinched.
  String get recenterRoute => _es ? 'Ver ruta' : 'Show route';

  String get verifyYourIdentity =>
      _es ? 'Verifica tu identidad' : 'Verify your identity';

  // ── Driver: add bank account for weekly payouts ──
  String get addBankAccountTitle =>
      _es ? 'Agrega tu banco' : 'Add your bank';
  String get editBankAccountTitle =>
      _es ? 'Edita tu banco' : 'Edit bank account';
  String get editBankAccountSubtitle => _es
      ? 'La cuenta que guardes aquí reemplaza a la anterior.'
      : 'The account you save here replaces the previous one.';
  String get addBankAccountSubtitle => _es
      ? 'Tus ganancias de la semana llegan aquí cada miércoles, sin comisión.'
      : 'Your weekly earnings land here every Wednesday, with no fee.';
  String get accountHolderName =>
      _es ? 'Nombre del titular' : 'Name of account holder';
  String get routingNumberInvalid => _es
      ? 'Ese routing number no es válido'
      : "That routing number isn't valid";
  String get bankAccountNumber =>
      _es ? 'Número de cuenta' : 'Bank account number';
  String get reenterAccountNumber =>
      _es ? 'Repite el número de cuenta' : 'Re-enter account number';
  String get accountNumbersDoNotMatch =>
      _es ? 'Los números no coinciden' : "The numbers don't match";
  String get bankNumbersNeverStored => _es
      ? 'Cifrado de extremo a extremo. Tu información bancaria permanece '
          'confidencial.'
      : 'End-to-end encryption. Your banking information remains confidential.';

  /// Shown when the driver is sent to Stripe to finish verifying their
  /// account before a bank can be linked.
  String get verifyIdentityToGetPaid => _es
      ? 'Verifica tu cuenta con Stripe y vuelve para agregar tu banco'
      : 'Verify your account with Stripe, then come back to add your bank';

  /// Shown when the call button cannot dial — no number on the trip, or the
  /// handset has no phone app. Silence there read as a frozen button.
  String get callDriverUnavailable => _es
      ? 'No se puede llamar al conductor ahora mismo'
      : "Can't call the driver right now";

  /// Find-My pickup screen: what the compass arrow is for.
  String get findDriverFollowArrow => _es
      ? 'Encuentra a tu conductor siguiendo la flecha'
      : 'Find your driver by following the arrow';

  // ── Face Liveness Screen (new step keys) ──────────────────────────────────
  String get centerYourFace => _es ? 'Centra tu rostro' : 'Center your face';
  String get turnHeadRight =>
      _es ? 'Gira la cabeza a la derecha' : 'Turn your head right';
  String get turnHeadLeft =>
      _es ? 'Gira la cabeza a la izquierda' : 'Turn your head left';
  String get faceDetected => _es ? 'Rostro detectado' : 'Face detected';
  String get positionYourFace =>
      _es ? 'Coloca tu rostro en el óvalo' : 'Position your face in the oval';
  String get faceFeedbackNoFace => _es
      ? 'No se detecta tu rostro — revisa la iluminación'
      : 'No face detected — check the lighting';
  String get faceFeedbackMoveCloser =>
      _es ? 'Acércate un poco' : 'Move closer';
  String get faceFeedbackMoveAway =>
      _es ? 'Aléjate un poco' : 'Move a little farther';
  String get faceFeedbackCenter => _es
      ? 'Centra tu rostro en el óvalo'
      : 'Center your face in the oval';
  String get faceDetectionError => _es
      ? 'La detección de rostro no funciona en este dispositivo — '
          'reinicia e inténtalo de nuevo'
      : "Face detection isn't working on this device — please restart and "
          'try again';
  String get faceCameraPermissionDenied => _es
      ? 'Se necesita acceso a la cámara para verificar tu identidad'
      : 'Camera access is needed to verify your identity';
  String get faceCameraError => _es
      ? 'No se pudo iniciar la cámara — reinicia e inténtalo de nuevo'
      : "The camera couldn't start — please restart and try again";

  // ── Coming Soon ────────────────────────────────────────────────────────────
  String get comingSoon => _es ? 'Próximamente' : 'Coming Soon';

  // ── Vehicle Insurance ──────────────────────────────────────────────────────
  String get vehicleInsuranceValid =>
      _es ? 'Seguro del vehículo válido' : 'Vehicle Insurance Valid';
  String get insuranceExpiredLabel =>
      _es ? 'Seguro vencido' : 'Insurance Expired';
  String get insuranceUpToDate =>
      _es ? 'Seguro al día' : 'Insurance is up to date';
  String get tapToUpdateDocuments =>
      _es ? 'Toca para actualizar documentos' : 'Tap to update documents';
  String get notAssigned => _es ? 'No asignado' : 'Not assigned';
  String get setByDispatch => _es ? 'Asignado por despacho' : 'Set by dispatch';

  // ── Documents Screen ───────────────────────────────────────────────────────
  String get documentsLockedNote => _es
      ? 'Las actualizaciones de documentos son gestionadas por el equipo de Cruise. Contacta soporte si necesitas actualizar un documento.'
      : 'Document updates are managed by the Cruise team. Contact support if you need to update a document.';

  // ── Sounds Screen ──────────────────────────────────────────────────────────
  String get syncedWithDeviceVolume => _es
      ? 'Sincronizado con el volumen del dispositivo'
      : 'Synced with device volume';
  String get adjustWithPhoneVolumeButtons => _es
      ? 'Ajusta con los botones de volumen de tu teléfono'
      : "Adjust using your phone's volume buttons";

  // ── Opportunities Screen ───────────────────────────────────────────────────
  String get peakHoursBonusTitle =>
      _es ? 'Bono de Horas Pico' : 'Peak Hours Bonus';
  String get peakHoursBonusDesc => _es
      ? 'Gana hasta 2x durante las horas pico de demanda (7-9 AM, 5-8 PM entre semana). El precio dinámico se aplica automáticamente.'
      : 'Earn up to 2x during peak demand hours (7-9 AM, 5-8 PM weekdays). Surge pricing automatically applies.';
  String get weekendWarriorBonusTitle =>
      _es ? 'Guerrero de Fin de Semana' : 'Weekend Warrior';
  String get weekendWarriorBonusDesc => _es
      ? 'Completa 20+ viajes los fines de semana para desbloquear un bono de \$50 cada semana.'
      : 'Complete 20+ trips on weekends to unlock a \$50 bonus each week.';
  String get airportRunsTitle => _es ? 'Viajes al Aeropuerto' : 'Airport Runs';
  String get airportRunsDesc => _es
      ? 'Los viajes al aeropuerto generan tarifas premium. Mantente cerca del aeropuerto para más viajes de alto valor.'
      : 'Airport pickups and drop-offs earn premium fares. Stay near airports for more high-value trips.';
  String get eventSurgeTitle => _es ? 'Surge de Eventos' : 'Event Surge';
  String get eventSurgeDesc => _es
      ? 'Grandes eventos = grandes ganancias. Revisa el mapa para zonas de aumento cerca de conciertos, partidos y festivales.'
      : 'Major events = major earnings. Check the map for surge zones near concerts, games, and festivals.';
  String get consecutiveTripBonusTitle =>
      _es ? 'Bono por Viajes Consecutivos' : 'Consecutive Trip Bonus';
  String get consecutiveTripBonusDesc => _es
      ? 'Acepta 3 viajes seguidos sin desconectarte para ganar un bono extra de \$10.'
      : 'Accept 3 trips in a row without going offline to earn an extra \$10 bonus.';

  // ── Work Hub Screen ────────────────────────────────────────────────────────
  String get rideServicesTitle => _es ? 'Servicio de Viajes' : 'Ride Services';
  String get rideServicesDesc => _es
      ? 'Tu servicio principal. Recoge y deja pasajeros de forma segura y eficiente.'
      : 'Your primary service. Pick up and drop off riders safely and efficiently.';
  String get packageDeliveryTitle =>
      _es ? 'Entrega de Paquetes' : 'Package Delivery';
  String get packageDeliveryDesc => _es
      ? 'Entrega paquetes para negocios locales e individuos.'
      : 'Deliver packages for local businesses and individuals.';
  String get groceryDeliveryTitle =>
      _es ? 'Entrega de Supermercado' : 'Grocery Delivery';
  String get groceryDeliveryDesc => _es
      ? 'Asóciate con supermercados locales para entrega en el mismo día.'
      : 'Partner with local grocery stores for same-day delivery.';
  String get scheduledRidesWorkHubTitle =>
      _es ? 'Viajes Programados' : 'Scheduled Rides';
  String get scheduledRidesWorkHubDesc => _es
      ? 'Acepta viajes pre-programados para ganancias garantizadas en horarios fijos.'
      : 'Accept pre-scheduled rides for guaranteed earnings at set times.';

  // ── Refer Friends Screen ───────────────────────────────────────────────────
  String get referEarn200 => _es ? 'GANA \$200' : 'EARN \$200';
  String get referFriendsSubtitle => _es
      ? 'por cada amigo que se registre y complete sus primeros 50 viajes'
      : 'for every friend who signs up and completes their first 50 rides';
  String get shareInviteLinkBtn =>
      _es ? 'Compartir Enlace de Invitación' : 'Share Invite Link';
  String get referDriverShareText => _es
      ? '¡Conduce con Cruise y gana excelente dinero! Regístrate con mi enlace: https://cruiseinride.com/drive'
      : 'Drive with Cruise and earn great money! Sign up with my link: https://cruiseinride.com/drive';
  String get howItWorksTitle => _es ? 'Cómo funciona' : 'How it works';
  String get howItWorksDesc => _es
      ? '1. Comparte tu enlace de invitación único\n2. Tu amigo se registra y completa sus primeros 50 viajes\n3. Ganas un bono de \$200'
      : '1. Share your unique invite link\n2. Your friend signs up and completes their first 50 rides\n3. You earn \$200 bonus';
  String get noLimitTitle => _es ? 'Sin Límite' : 'No Limit';
  String get noLimitDesc => _es
      ? 'Refiere a tantos amigos como quieras — no hay límite de cuánto puedes ganar.'
      : "Refer as many friends as you want — there's no cap on how much you can earn.";

  // ── Driver Referral Screen (live, end-to-end) ──────────────────────────────
  String driverEarnHero(String amount) => _es ? 'GANA $amount' : 'EARN $amount';
  String driverEarnSub(int rides, int days) => _es
      ? 'por cada conductor que refieras y complete sus primeros $rides viajes en $days días'
      : 'for every driver you refer who completes their first $rides rides within $days days';
  String driverShareIntro(String amount) => _es
      ? '¡Conduce con Cruise y gana $amount cuando completes tus primeros viajes!'
      : 'Drive with Cruise and earn $amount when you complete your first rides!';
  String driverShareSteps(int rides) => _es
      ? '1. Regístrate como conductor con mi código\n2. Completa $rides viajes\n3. Tu referidor gana un bono'
      : '1. Sign up as a driver with my code\n2. Complete $rides rides\n3. Your referrer earns a bonus';
  String get driverShareSubject =>
      _es ? 'Conduce con Cruise' : 'Drive with Cruise';
  String get driverHowStep1 => _es
      ? 'Comparte tu código único con otros conductores.'
      : 'Share your unique code with other drivers.';
  String driverHowStep2(int rides, int days) => _es
      ? 'Se registra como conductor con tu código y completa $rides viajes en $days días.'
      : 'They sign up as a driver with your code and complete $rides rides within $days days.';
  String driverHowStep3(String amount) => _es
      ? 'Ganas $amount, agregado a tu balance pendiente y disponible en tu próximo retiro.'
      : 'You earn $amount, added to your pending balance and available in your next payout.';
  String get yourCode => _es ? 'TU CÓDIGO' : 'YOUR CODE';
  String get yourReferrals => _es ? 'TUS REFERIDOS' : 'YOUR REFERRALS';
  String get earnedLabel => _es ? 'Ganado' : 'Earned';
  String get pendingLabel => _es ? 'Pendiente' : 'Pending';
  String get referralsLabel => _es ? 'Referidos' : 'Referrals';
  String get statusPaid => _es ? 'PAGADO' : 'PAID';
  String get statusExpired => _es ? 'EXPIRADO' : 'EXPIRED';
  String get statusInProgress => _es ? 'EN PROGRESO' : 'IN PROGRESS';
  String get ridesLabel => _es ? 'viajes' : 'rides';

  // ── Rider Invite Friends Screen (2026-08-16 redesign) ──────────────────────
  // inviteFriendsTitle already exists below ('Invitar Amigos' / 'Invite
  // Friends') — reused, not duplicated.
  String referPendingBonusTitle(String amount) =>
      _es ? '🎁 Tienes \$$amount esperándote' : '🎁 You have \$$amount waiting';
  String referPendingBonusSub(int trips, String minFare) => _es
      ? 'Completa $trips viajes de \$$minFare+ y son tuyos.'
      : 'Complete $trips rides of \$$minFare+ and they are yours.';
  String get cruiseCashLabel => _es ? 'Cruise Cash' : 'Cruise Cash';
  String lifetimeEarned(String amount) =>
      _es ? 'Total ganado: $amount' : 'Lifetime earned: $amount';
  String get transferLabel => _es ? 'Transferir' : 'Transfer';
  String get copyLabel => _es ? 'COPIAR' : 'COPY';
  String get shareInviteLabel => _es ? 'Compartir invitación' : 'Share invite';
  String get referStep1Title => _es ? 'Comparte tu código' : 'Share your code';
  String get referStep1Body => _es
      ? 'Mándaselo a tus amigos por WhatsApp, SMS o cualquier app.'
      : 'Send it to friends via WhatsApp, SMS or any app.';
  String get referStep2Title => _es ? 'Tu amigo viaja' : 'Your friend rides';
  String referStep2Body(int trips, String minFare) => _es
      ? 'Se registra con tu código y completa $trips viajes de \$$minFare+.'
      : 'They sign up with your code and complete $trips rides of \$$minFare+.';
  String referStep3Title(String amount) =>
      _es ? 'Los dos ganan \$$amount' : 'You both earn \$$amount';
  String get referStep3Body => _es
      ? 'Cruise Cash al instante para los dos. Úsalo en cualquier viaje o transfiérelo.'
      : 'Instant Cruise Cash for both. Spend it on any ride or transfer it.';
  String get gotInviteCode =>
      _es ? '¿Tienes un código de invitación?' : 'Got an invite code?';
  String get redeemLabel => _es ? 'USAR' : 'REDEEM';
  String linkedToName(String name) =>
      _es ? '¡Ahora estás vinculado a $name!' : "You're now linked to $name!";
  String get codeRedeemed => _es ? '¡Código aplicado!' : 'Code redeemed!';
  String qualifiedOfTotal(int qualified, int total) =>
      _es ? '$qualified de $total calificados' : '$qualified of $total qualified';
  String get noReferralsYet =>
      _es ? 'Aún no tienes referidos' : 'No referrals yet';
  String get earnedBadge => _es ? 'GANADO' : 'EARNED';
  String get recentActivityLabel =>
      _es ? 'Actividad reciente' : 'Recent activity';
  String get txReferralBonus => _es ? 'Bono de referido' : 'Referral bonus';
  String get txAppliedToRide => _es ? 'Aplicado a un viaje' : 'Applied to ride';
  String get txTransferReceived =>
      _es ? 'Transferencia recibida' : 'Transfer received';
  String get txTransferSent => _es ? 'Transferencia enviada' : 'Transfer sent';
  String get txAdjustment => _es ? 'Ajuste' : 'Adjustment';
  String get shareSheetFailed => _es
      ? 'No se pudo abrir el menú de compartir. Copia tu código.'
      : 'Could not open share sheet. Try copying your code instead.';
  String get referralCodeOptional =>
      _es ? 'Código de referido (opcional)' : 'Referral code (optional)';
  String get driverWelcomeBonusNote => _es
      ? 'Gana \$25 al completar tus primeros 2 viajes'
      : 'Earn \$25 after your first 2 rides';

  // ── Driver referral milestones (2026-08-16) ─────────────────────────────────
  String driverEarnSubMilestones(
          String m1Amount, int m1Rides, String m2Amount, int m2Rides) =>
      _es
          ? 'Gana $m1Amount cuando tu referido complete $m1Rides viajes, y $m2Amount más cuando llegue a $m2Rides'
          : 'Earn $m1Amount when your referral completes $m1Rides rides, plus $m2Amount more when they reach $m2Rides';
  String driverHowStep2Milestones(
          String m1Amount, int m1Rides, String m2Amount, int m2Rides) =>
      _es
          ? 'Se registra como conductor con tu código. A los $m1Rides viajes ganas $m1Amount; a los $m2Rides, $m2Amount más.'
          : 'They sign up as a driver with your code. At $m1Rides rides you earn $m1Amount; at $m2Rides, $m2Amount more.';
  String driverHowWelcomeBonus(String amount, int rides) => _es
      ? 'Tu referido también gana: $amount al completar sus primeros $rides viajes.'
      : 'Your referral wins too: $amount after their first $rides rides.';
  String driverShareWelcome(String amount, int rides) => _es
      ? '¡Conduce con Cruise! Regístrate con mi código y gana $amount al completar tus primeros $rides viajes.'
      : 'Drive with Cruise! Sign up with my code and earn $amount after your first $rides rides.';
  String driverShareMilestones(
          String m1Amount, int m1Rides, String m2Amount, int m2Rides) =>
      _es
          ? 'Yo gano $m1Amount cuando completes $m1Rides viajes, ¡y $m2Amount más cuando llegues a $m2Rides!'
          : 'I earn $m1Amount when you complete $m1Rides rides, and $m2Amount more when you reach $m2Rides!';
  String get statusMilestone1 => _es ? 'HITO 1 PAGADO' : 'MILESTONE 1 PAID';

  // ── Driver Insurance Screen ────────────────────────────────────────────────
  String get cruiseDriverProtectionTitle =>
      _es ? 'Protección para Conductores Cruise' : 'Cruise Driver Protection';
  String get cruiseDriverProtectionDesc => _es
      ? 'Estás cubierto desde el momento en que aceptas una solicitud de viaje hasta que el viaje se completa.'
      : "You're covered from the moment you accept a ride request until the trip is completed.";
  String get liabilityCoverageTitle =>
      _es ? 'Cobertura de Responsabilidad' : 'Liability Coverage';
  String get liabilityCoverageDesc => _es
      ? 'Hasta \$1,000,000 en cobertura de responsabilidad a terceros durante un viaje.'
      : 'Up to \$1,000,000 in third-party liability coverage while on a trip.';
  String get collisionCoverageTitle =>
      _es ? 'Cobertura de Colisión' : 'Collision Coverage';
  String get collisionCoverageDesc => _es
      ? 'Cobertura de daños al vehículo durante un viaje activo, sujeto a deducible.'
      : 'Vehicle damage coverage while on an active trip, subject to deductible.';
  String get uninsuredMotoristTitle =>
      _es ? 'Motorista No Asegurado' : 'Uninsured Motorist';
  String get uninsuredMotoristDesc => _es
      ? 'Protección contra conductores no asegurados o insuficientemente asegurados durante viajes activos.'
      : 'Protection against uninsured or underinsured drivers during active trips.';
  String get personalInsuranceTitle =>
      _es ? 'Seguro Personal' : 'Personal Insurance';
  String get personalInsuranceDesc => _es
      ? 'Recuerda: debes mantener tu propio seguro de auto personal para conducir con Cruise.'
      : 'Remember: you must maintain your own personal auto insurance to drive with Cruise.';

  // ── Tax Info Screen ────────────────────────────────────────────────────────
  String get taxDocumentsTitle => _es ? 'Documentos Fiscales' : 'Tax Documents';
  String get taxDocumentsDesc => _es
      ? 'Tus formularios fiscales 1099 estarán disponibles aquí al final del año fiscal si ganaste más de \$600.'
      : 'Your 1099 tax forms will be available here at the end of the tax year if you earned more than \$600.';
  String get earningsSummaryTitle =>
      _es ? 'Resumen de Ganancias' : 'Earnings Summary';
  String get earningsSummaryDesc => _es
      ? 'Ve y descarga tu resumen de ganancias anual para la declaración de impuestos.'
      : 'View and download your annual earnings summary for tax filing purposes.';
  String get deductibleExpensesTitle =>
      _es ? 'Gastos Deducibles' : 'Deductible Expenses';
  String get deductibleExpensesDesc => _es
      ? 'Rastrea millaje, gasolina, mantenimiento y otros gastos que podrían ser deducibles de impuestos.'
      : 'Track mileage, gas, maintenance, and other expenses that may be tax deductible.';
  String get taxTipsTitle => _es ? 'Consejos Fiscales' : 'Tax Tips';
  String get taxTipsDesc => _es
      ? 'Como contratista independiente, puede que necesites pagar impuestos estimados trimestrales. Consulta a un profesional fiscal.'
      : 'As an independent contractor, you may need to pay quarterly estimated taxes. Consult a tax professional.';

  // ── Plus Card Screen ───────────────────────────────────────────────────────
  String get instantEarningsAccessTitle =>
      _es ? 'Acceso Instantáneo a Ganancias' : 'Instant Earnings Access';
  String get instantEarningsAccessDesc => _es
      ? 'Recibe tus ganancias instantáneamente después de cada viaje — sin esperar pagos semanales.'
      : 'Get your earnings instantly after every trip — no waiting for weekly payouts.';
  String get cashBackRewardsTitle =>
      _es ? 'Recompensas de Cashback' : 'Cash Back Rewards';
  String get cashBackRewardsDesc => _es
      ? 'Gana 3% de cashback en gasolina, 2% en mantenimiento de auto, y 1% en todo lo demás.'
      : 'Earn 3% cash back on gas, 2% on car maintenance, and 1% on everything else.';
  String get noAnnualFeeTitle => _es ? 'Sin Cuota Anual' : 'No Annual Fee';
  String get noAnnualFeeDesc => _es
      ? 'La Tarjeta Cruise Plus no tiene cuotas anuales. Solo conduce y gana.'
      : 'The Cruise Plus Card has zero annual fees. Just drive and earn.';

  // ── Learning Center Screen ─────────────────────────────────────────────────
  String get lcGettingStartedTitle =>
      _es ? 'Primeros Pasos' : 'Getting Started';
  String get lcGettingStartedSubtitle => _es
      ? 'Todo lo que necesitas saber sobre tus primeros viajes con Cruise.'
      : 'Everything you need to know about your first trips with Cruise.';
  String get lcGettingStarted1 => _es
      ? 'Descarga la app de Conductor de Cruise y asegúrate de que tu cuenta esté completamente aprobada.'
      : 'Download the Cruise Driver app and make sure your account is fully approved.';
  String get lcGettingStarted2 => _es
      ? 'Configura tu disponibilidad — toca "Conectarse" para empezar a recibir solicitudes de viaje.'
      : 'Set your availability — tap "Go Online" to start receiving ride requests.';
  String get lcGettingStarted3 => _es
      ? 'Mantén tu teléfono cargado y el GPS habilitado en todo momento mientras conduces.'
      : 'Keep your phone charged and GPS enabled at all times while driving.';
  String get lcGettingStarted4 => _es
      ? 'Tu primer viaje: acepta la solicitud, navega hacia la recogida, saluda al pasajero profesionalmente.'
      : 'Your first ride: accept the request, navigate to pickup, greet the rider professionally.';
  String get lcGettingStarted5 => _es
      ? 'Completa el viaje y califica a tu pasajero. Las ganancias se acreditan a tu cuenta instantáneamente.'
      : 'Complete the ride and rate your rider. Earnings are credited to your account instantly.';
  String get lcNavTipsTitle =>
      _es ? 'Consejos de Navegación' : 'Navigation Tips';
  String get lcNavTipsSubtitle => _es
      ? 'Usa apps de GPS efectivamente, aprende sobre rutas preferidas y maneja desvíos.'
      : 'Use GPS apps effectively, learn about preferred routes, and handle detours.';
  String get lcNavTip1 => _es
      ? 'Configura tu app de navegación preferida en Configuración → Navegación.'
      : 'Set your preferred navigation app under Settings → Navigation.';
  String get lcNavTip2 => _es
      ? 'Siempre sigue la ruta sugerida a menos que el pasajero solicite un camino específico.'
      : 'Always follow the suggested route unless the rider requests a specific path.';
  String get lcNavTip3 => _es
      ? 'Para desvíos por tráfico, recalcula en tu app de navegación y notifica al pasajero.'
      : 'For detours due to traffic, re-route through your navigation app and notify the rider.';
  String get lcNavTip4 => _es
      ? 'Recogidas en el aeropuerto: sigue los letreros del terminal y espera en la zona de rideshare designada.'
      : 'Airport pickups: follow terminal signs and wait in the designated rideshare pickup zone.';
  String get lcNavTip5 => _es
      ? 'Evita giros en U en calles transitadas — da vuelta a la derecha para una navegación más segura.'
      : 'Avoid U-turns on busy roads — make a right block instead for safer navigation.';
  String get lcRiderCommTitle =>
      _es ? 'Comunicación con Pasajeros' : 'Rider Communication';
  String get lcRiderCommSubtitle => _es
      ? 'Mejores prácticas para saludar pasajeros, manejar solicitudes especiales y obtener calificaciones de 5 estrellas.'
      : 'Best practices for greeting riders, handling special requests, and earning 5-star ratings.';
  String get lcRiderComm1 => _es
      ? 'Saluda a los pasajeros amablemente: "Hola, soy [nombre], vamos a [destino]."'
      : 'Greet riders warmly: "Hi, I\'m [name], headed to [destination]."';
  String get lcRiderComm2 => _es
      ? 'Pregunta si tienen una ruta preferida o preferencia musical.'
      : 'Ask if they have a preferred route or music preference.';
  String get lcRiderComm3 => _es
      ? "Mantén la conversación ligera — sigue el ritmo del pasajero. Algunos prefieren viajes en silencio."
      : "Keep conversation light — follow the rider's lead. Some prefer quiet rides.";
  String get lcRiderComm4 => _es
      ? 'Para solicitudes especiales (paradas extra, espera), comunica claramente y actualiza la app.'
      : 'For special requests (extra stops, waiting), communicate clearly and update the app.';
  String get lcRiderComm5 => _es
      ? 'Termina el viaje profesionalmente: "¡Gracias por viajar con Cruise, que tengas un excelente día!"'
      : 'End the ride professionally: "Thanks for riding with Cruise, have a great day!"';
  String get lcSafetyTitle =>
      _es ? 'Protocolos de Seguridad' : 'Safety Protocols';
  String get lcSafetySubtitle => _es
      ? 'Sabe qué hacer en emergencias, accidentes y situaciones incómodas.'
      : 'Know what to do in emergencies, accidents, and uncomfortable situations.';
  String get lcSafety1 => _es
      ? 'Emergencia: detente de forma segura y llama al 911. Toca el botón SOS en la app para alertar a Cruise.'
      : 'Emergency: pull over safely and call 911. Tap the SOS button in the app to alert Cruise.';
  String get lcSafety2 => _es
      ? 'Accidentes: documenta todo con fotos. Reporta a través de la app dentro de 24 horas.'
      : 'Accidents: document everything with photos. Report through the app within 24 hours.';
  String get lcSafety3 => _es
      ? 'Situaciones incómodas: tienes el derecho de terminar cualquier viaje si te sientes inseguro.'
      : 'Uncomfortable situations: you have the right to end any ride if you feel unsafe.';
  String get lcSafety4 => _es
      ? 'Nunca manejes bajo la influencia de alcohol, medicamentos u otras sustancias.'
      : 'Never drive under the influence of alcohol, medication, or other substances.';
  String get lcSafety5 => _es
      ? 'Revisa tu vehículo antes de salir a conducir: frenos, luces, espejos y presión de llantas.'
      : 'Check your vehicle before you start driving: brakes, lights, mirrors, and tire pressure.';
  String get lcMaxEarningsTitle =>
      _es ? 'Maximizar Ganancias' : 'Maximizing Earnings';
  String get lcMaxEarningsSubtitle => _es
      ? 'Consejos pro para encontrar zonas de aumento, horas de manejo óptimas y reducir gastos.'
      : 'Pro tips for finding surge zones, optimal driving hours, and reducing expenses.';
  String get lcMaxEarnings1 => _es
      ? 'Horas pico (7-9 AM y 5-8 PM entre semana) ofrecen hasta 2× de ganancias — prioriza estos horarios.'
      : 'Peak hours (7-9 AM and 5-8 PM weekdays) offer up to 2× earnings — prioritize these.';
  String get lcMaxEarnings2 => _es
      ? 'Noches de fin de semana (Vie/Sáb 10 PM–2 AM) son los períodos de mayor demanda en la mayoría de ciudades.'
      : 'Weekend nights (Fri/Sat 10 PM–2 AM) are the highest demand periods in most cities.';
  String get lcMaxEarnings3 => _es
      ? 'Mantente cerca de distritos de entretenimiento populares y centros de tránsito entre viajes.'
      : 'Stay near popular entertainment districts and transit hubs between rides.';
  String get lcMaxEarnings4 => _es
      ? 'Completa 20+ viajes de fin de semana para desbloquear el bono Guerrero de Fin de Semana de \$50.'
      : 'Complete 20+ weekend trips to unlock the \$50 Weekend Warrior bonus.';
  String get lcMaxEarnings5 => _es
      ? 'Rastrea tus gastos: gasolina, mantenimiento y comisiones de la app suelen ser deducibles de impuestos.'
      : 'Track your expenses: gas, maintenance, and app fees are often tax deductible.';
  String get lcVehicleMaintenanceTitle =>
      _es ? 'Mantenimiento del Vehículo' : 'Vehicle Maintenance';
  String get lcVehicleMaintenanceSubtitle => _es
      ? 'Mantén tu auto en óptimas condiciones con horarios de mantenimiento y consejos de cuidado.'
      : 'Keep your car in top shape with maintenance schedules and care tips.';
  String get lcVehicleMaintenance1 => _es
      ? 'Cambio de aceite cada 5,000 millas o según lo recomiende el fabricante de tu vehículo.'
      : 'Oil change every 5,000 miles or as recommended by your vehicle manufacturer.';
  String get lcVehicleMaintenance2 => _es
      ? 'Rotación de llantas cada 6,000–8,000 millas. Revisa la presión semanalmente.'
      : 'Tire rotation every 6,000–8,000 miles. Check pressure weekly.';
  String get lcVehicleMaintenance3 => _es
      ? 'Mantén el interior limpio — aspira semanalmente y usa un aromatizante de auto.'
      : 'Keep the interior clean — vacuum weekly and use a car freshener.';
  String get lcVehicleMaintenance4 => _es
      ? 'Reemplaza el filtro de aire de cabina cada 15,000–25,000 millas para un viaje con olor fresco.'
      : 'Replace cabin air filter every 15,000–25,000 miles for a fresh-smelling ride.';
  String get lcVehicleMaintenance5 => _es
      ? 'Mantén la inspección del vehículo y los documentos de seguro actualizados en la app Cruise.'
      : 'Keep vehicle inspection and insurance documents up to date in the Cruise app.';

  // ── New Driver Instructions Screen ────────────────────────────────────────
  String get newDriverWelcomeTitle =>
      _es ? '¡Bienvenido a Cruise!' : 'Welcome to Cruise!';
  String get youreApprovedTitle =>
      _es ? '¡Estás Aprobado!' : "You're Approved!";
  String get threeThingsToDo => _es
      ? 'Aquí hay 3 cosas que hacer antes de tu primer viaje'
      : 'Here are 3 things to do before your first ride';
  String get verifyDocumentsTitle =>
      _es ? 'Verifica tus documentos' : 'Verify your documents';
  String get verifyDocumentsBody => _es
      ? "Asegúrate de que tu Licencia de Conducir, Seguro del Vehículo y Registro estén subidos y aprobados en la sección de Documentos. Mantenlos actualizados — los documentos vencidos suspenderán tu cuenta."
      : "Make sure your Driver's License, Vehicle Insurance, and Registration are uploaded and approved in the Documents section. Keep them up to date — expired documents will suspend your account.";
  String get setupNavigationTitle =>
      _es ? 'Configura tu navegación' : 'Set up your navigation';
  String get setupNavigationBody => _es
      ? 'Ve a Configuración → Navegación y selecciona tu app de mapas preferida (Cruise Maps, Google Maps, Apple Maps o Waze). Esta es la app que se abrirá cuando aceptes un viaje.'
      : 'Go to Settings → Navigation and select your preferred map app (Cruise Maps, Google Maps, Apple Maps, or Waze). This is the app that will open when you accept a ride.';
  String get goOnlineAndEarnTitle =>
      _es ? 'Conéctate y gana' : 'Go online and earn';
  String get goOnlineAndEarnBody => _es
      ? 'Toca "Conectarse" en la pantalla principal para empezar a recibir solicitudes de viaje. Conduce durante las horas pico (7–9 AM y 5–8 PM entre semana) para ganancias máximas. ¡Completa tu primer viaje y recibe el pago instantáneamente!'
      : 'Tap "Go Online" on the home screen to start receiving ride requests. Drive during peak hours (7–9 AM and 5–8 PM weekdays) for maximum earnings. Complete your first ride and get paid instantly!';
  String get letsGoBtn => _es ? '¡Vamos!' : "Let's Go!";

  // ── About Screen ───────────────────────────────────────────────────────────
  String get shareAppText => _es
      ? '¡Mira Cruise — la mejor experiencia de viaje! 🚗\nhttps://cruiseinride.com/download'
      : 'Check out Cruise - the best ride experience! 🚗\nhttps://cruiseinride.com/download';

  // ── Driver Trip Accept Screen ──
  String get tripCompleted => _es ? 'Viaje Finalizado' : 'Trip Completed';
  String get continueBtn => _es ? 'Continuar' : 'Continue';
  String get directions => _es ? 'Direcciones' : 'Directions';
  String get cancelBtn => _es ? 'Cancelar' : 'Cancel';
  String get noJustReport => _es ? 'No, solo reportar' : 'No, just report';
  String get yesCall911 => _es ? 'Sí, llamar al 911' : 'Yes, call 911';
  String get reportSent => _es
      ? 'Reporte enviado. El equipo lo revisará.'
      : 'Report sent. The team will review it.';
  String get reportError =>
      _es ? 'Error al enviar reporte' : 'Error sending report';
  String get pickupAddressProblem =>
      _es ? 'Problema con dirección de recogida' : 'Pickup address problem';
  String get dropoffAddressProblem =>
      _es ? 'Problema con dirección de destino' : 'Dropoff address problem';
  String get tripProblem => _es ? 'Problema con el viaje' : 'Trip problem';
  String get safetyCenter => _es ? 'Centro de seguridad' : 'Safety Center';

  /// One panel for the two header buttons the trip screen used to carry
  /// separately — emergency/safety on top, support below.
  String get safetyAndSupport =>
      _es ? 'Seguridad y soporte' : 'Safety & Support';
  String get safetyAndSupportSubtitle => _es
      ? 'Emergencias, reportes y ayuda con el viaje'
      : 'Emergency, reports and trip help';
  String get openAppleMaps =>
      _es ? 'Abrir en Apple Maps' : 'Open in Apple Maps';
  String get openGoogleMaps =>
      _es ? 'Abrir en Google Maps' : 'Open in Google Maps';

  // ── Driver Online / Offers ──
  String get newRideOffer => _es ? 'Nueva oferta de viaje' : 'New Ride Offer';
  String get riderNotConfirmedStarting => _es
      ? 'El rider no ha confirmado, comenzando viaje...'
      : 'Rider has not confirmed, starting trip...';
  String get resumeNow => _es ? 'Reanudar ahora' : 'Resume Now';
  String get fifteenMin => _es ? '15 min' : '15 min';
  String get thirtyMin => _es ? '30 min' : '30 min';
  String get offerExpired => _es ? 'Oferta expirada' : 'Offer expired';
  String get navigateLabel => _es ? 'NAVEGAR' : 'NAVIGATE';

  // ── Driver Navigation ──
  String get callRider => _es ? 'Llamar al rider' : 'Call Rider';
  String get messageRider => _es ? 'Mensaje al rider' : 'Message Rider';
  String get reportWrongAddress =>
      _es ? 'Reportar dirección incorrecta' : 'Report Wrong Address';
  String get riderNoShow => _es ? 'Rider no apareció' : 'Rider No-Show';
  String get endTripEarly => _es ? 'Terminar viaje temprano' : 'End Trip Early';
  String get resumeLabel => _es ? 'Reanudar' : 'Resume';
  String get exitLabel => _es ? 'Salir' : 'Exit';
  String get mphLabel => _es ? 'mph' : 'mph';
  String get maxLabel => _es ? 'MÁX' : 'MAX';

  // ── Driver Report Dialog ──
  String get pleaseDescribeProblem =>
      _es ? 'Por favor describe el problema' : 'Please describe the problem';

  // ── Driver Action Panel ──
  String get timeLabel => _es ? 'Tiempo' : 'Time';

  // ── Driver Info Card (tracking) ──
  String get phoneNotAvailable =>
      _es ? 'Número no disponible' : 'Phone number not available';

  // ── Home Screen ──
  String get editHomeAddress =>
      _es ? 'Editar dirección de casa' : 'Edit Home address';
  String get editWorkAddress =>
      _es ? 'Editar dirección de trabajo' : 'Edit Work address';
  String get savePlaceN => _es ? 'Guardar lugar' : 'Save Place';
  String get editPlaceN => _es ? 'Editar lugar' : 'Edit Place';

  // ── Help Screen ──
  String get updateEmailOrPhone =>
      _es ? 'Actualizar email o teléfono' : 'Update my email or phone';
  String get safetySection => _es ? 'Seguridad' : 'Safety';
  String get wasInAccident =>
      _es ? 'Tuve un accidente' : 'I was in an accident';
  String get driverMadeUnsafe => _es
      ? 'Mi conductor me hizo sentir inseguro'
      : 'My driver made me feel unsafe';
  String get gpsLocationIssues =>
      _es ? 'Problemas de GPS / ubicación' : 'GPS / location issues';
  String get notReceivingNotifs =>
      _es ? 'No recibo notificaciones' : 'Not receiving notifications';

  // ── Safety Screen ──
  String get quickActions => _es ? 'Acciones rápidas' : 'Quick Actions';
  String get shareTripStatus =>
      _es ? 'Compartir estado del viaje' : 'Share Trip Status';
  String get shareTripSubtitle => _es
      ? 'Envía tu ubicación en tiempo real a un contacto'
      : 'Send your real-time location to a contact';
  String get reportUnsafeRider =>
      _es ? 'Reportar rider inseguro' : 'Report Unsafe Rider';
  String get reportUnsafeSubtitle => _es
      ? 'Reportar comportamiento inseguro'
      : 'Flag unsafe behavior for review';
  String get currentTrip => _es ? 'Viaje actual' : 'Current Trip';
  String get emergency => _es ? 'Emergencia' : 'Emergency';
  String get call911Help =>
      _es ? 'Llama al 911 para ayuda inmediata' : 'Call 911 for immediate help';
  String get reportIssue => _es ? 'Reportar problema' : 'Report Issue';
  String get call911Emergency => _es ? 'Llamar al 911' : 'Call 911 emergency';
  String get noPhoneContacts => _es
      ? 'No hay números de teléfono en contactos'
      : 'No phone numbers in contacts';
  String get emergencyAlertSent =>
      _es ? 'Alerta de emergencia enviada' : 'Emergency alert sent';
  String get failedSendAlert =>
      _es ? 'Error al enviar alerta' : 'Failed to send alert';
  String get nameHint => _es ? 'Nombre' : 'Name';
  String get phoneNumberHint => _es ? 'Número de teléfono' : 'Phone number';

  // ── Wallet Screen ──
  String get retryBtn => _es ? 'Reintentar' : 'Retry';
  String get manageLabel => _es ? 'Administrar' : 'Manage';
  String get noPaymentMethods => _es
      ? 'No hay métodos de pago configurados'
      : 'No payment methods configured';
  String get addMethodDescription => _es
      ? 'Agrega al menos un método para pagar viajes'
      : 'Add at least one method to pay for rides';

  // ── Saved Addresses ──
  String get searchAddressHint =>
      _es ? 'Buscar dirección...' : 'Search address...';
  String get nameThisPlace => _es ? 'Nombrar este lugar' : 'Name this place';
  String get namePlaceHint =>
      _es ? 'Ej. Gimnasio, Casa de mamá' : 'e.g. Gym, Mom\'s house';
  String get saveBtn => _es ? 'Guardar' : 'Save';
  String get deleteAddress => _es ? '¿Eliminar dirección?' : 'Delete address?';
  String get deleteBtn => _es ? 'Eliminar' : 'Delete';

  // ── Referral Screen ──
  String get codeCopied =>
      _es ? '¡Código copiado!' : 'Code copied to clipboard!';
  String get shareWithFriends =>
      _es ? 'Compartir con amigos' : 'Share with Friends';
  String get applyBtn => _es ? 'Aplicar' : 'Apply';
  String get howItWorks => _es ? 'Cómo funciona' : 'How it works';

  // ── Trip Receipt ──
  String get pickupLabel2 => _es ? 'RECOGIDA' : 'PICKUP';
  String get dropoffLabel2 => _es ? 'DESTINO' : 'DROP-OFF';

  // ── Schedule Picker ──
  String get hourLabel => _es ? 'Hora' : 'Hour';

  // ── Bottom Nav (Driver) ──
  String get homeNav => _es ? 'Inicio' : 'Home';
  String get earningsNav => _es ? 'Ganancias' : 'Earnings';
  String get tripsNav => _es ? 'Viajes' : 'Trips';
  String get accountNav => _es ? 'Cuenta' : 'Account';

  // ── Misc ──
  String get lowLabel => _es ? 'Bajo' : 'Low';
  String get highLabel => _es ? 'Alto' : 'High';
  String get setDefault =>
      _es ? 'Establecer como predeterminado' : 'Set Default';
  String get sendVerificationCode =>
      _es ? 'Enviar código de verificación' : 'Send Verification Code';
  String get emailVerified =>
      _es ? '¡Email verificado exitosamente!' : 'Email verified successfully!';
  String get verifyBtn => _es ? 'Verificar' : 'Verify';
  String get codeResent => _es ? '¡Código reenviado!' : 'Code resent!';
  String get emailOption => _es ? 'Email' : 'Email';
  String get takePhotoSubtitle => _es
      ? 'Usa la cámara para capturar el documento'
      : 'Use camera to capture document';
  String get chooseFromGallerySubtitle =>
      _es ? 'Selecciona una foto existente' : 'Select an existing photo';
  String get couldNotShareTrip =>
      _es ? 'No se pudo compartir el viaje' : 'Could not share trip';

  // ── Additional Hardcoded Strings ──────────────────────────────────────────
  String get reconnecting => _es ? 'Reconectando...' : 'Reconnecting...';
  String get messageFailedToSend => _es
      ? 'No se pudo enviar el mensaje. Revisa tu conexión.'
      : 'Message failed to send. Check your connection.';
  String get waitingForGps =>
      _es ? 'Esperando ubicación GPS...' : 'Waiting for GPS location...';

  // ── Report Dialog ──
  String get reportProblemTitle => _es ? 'Reportar Problema' : 'Report Problem';
  String get helpUsImprove =>
      _es ? 'Ayúdanos a mejorar la app' : 'Help us improve the app';
  String get problemTypeLabel => _es ? 'Tipo de problema' : 'Problem type';
  String get descriptionLabel => _es ? 'Descripción' : 'Description';
  String get appCrashLabel => _es ? 'App se cerró' : 'App crashed';
  String get errorBugLabel => _es ? 'Error/Bug' : 'Error/Bug';
  String get featureRequestLabel => _es ? 'Sugerencia' : 'Suggestion';
  String get complaintLabel => _es ? 'Queja' : 'Complaint';
  String get otherLabel => _es ? 'Otro' : 'Other';
  String get submittingLabel => _es ? 'Enviando...' : 'Submitting...';
  String get submitReport => _es ? 'Enviar Reporte' : 'Submit Report';
  String get reportSentSuccess =>
      _es ? '✓ Reporte enviado. ¡Gracias!' : '✓ Report sent. Thank you!';

  // ── Navigation Panel ──
  String get openInGoogleMaps =>
      _es ? 'ABRIR EN GOOGLE MAPS' : 'OPEN IN GOOGLE MAPS';
  String get passengerFallback => _es ? 'Pasajero' : 'Rider';
  String exitNumberLabel(int n) => _es ? 'Salida $n' : 'Exit $n';

  // ── Driver Earnings ──
  String get payoutSetupFailed => _es
      ? 'No se pudo configurar los pagos. Intenta de nuevo más tarde.'
      : 'Could not set up payments. Please try again later.';
  String get payoutSetupUnavailable => _es
      ? 'Los pagos no están disponibles en este momento. Contacta soporte.'
      : 'Payouts are temporarily unavailable. Contact support.';
  String get couldNotLoadEarnings => _es
      ? 'No se pudieron cargar las ganancias. Toca el ícono para reintentar.'
      : 'Could not load earnings. Tap the icon to retry.';
  String get couldNotLoadPayoutData => _es
      ? 'No se pudieron cargar los datos de pago.'
      : 'Could not load payout data.';
  String get couldNotLoadPaymentMethods => _es
      ? 'No se pudieron cargar los métodos de pago. Toca reintentar.'
      : 'Could not load payment methods. Tap retry.';
  String get configurePayments =>
      _es ? 'Configurar Pagos' : 'Configure Payments';
  String get openingLabel => _es ? 'Abriendo...' : 'Opening...';
  String get failedToSetDefault => _es
      ? 'No se pudo cambiar el método predeterminado'
      : 'Could not change the default method';

  // ── Referral Screen (NEW) ──
  String get inviteFriendsTitle => _es ? 'Invitar Amigos' : 'Invite Friends';
  String get friendsJoined => _es ? 'Amigos unidos' : 'Friends Joined';
  String get bonusEarned => _es ? 'Bonificación ganada' : 'Bonus Earned';
  String get yourReferralCode =>
      _es ? 'Tu Código de Referido' : 'Your Referral Code';
  String get friendsYouveInvited =>
      _es ? 'Amigos que has invitado' : "Friends You've Invited";
  String get shareYourCode => _es ? 'Comparte tu código' : 'Share your code';
  String get friendSignsUp => _es ? 'Tu amigo se registra' : 'Friend signs up';
  String get youBothEarn => _es ? 'Ambos ganan \$10' : 'You both earn \$10';
  String get shareCodeDescription => _es
      ? 'Envía tu código único a tus amigos.'
      : 'Send your unique code to friends.';
  String get friendSignsUpDescription => _es
      ? 'Tu amigo completa su primer viaje.'
      : 'Your friend completes their first ride.';
  String get youBothEarnDescription =>
      _es ? '¡Ambos reciben \$10 de crédito!' : 'You both get \$10 credit!';
  String codeAppliedCredit(String amount) => _es
      ? '🎉 ¡Código aplicado! \$$amount de crédito añadido a tu cuenta.'
      : '🎉 Code applied! \$$amount credit added to your account.';

  // ── Saved Addresses ──
  String get failedToSaveAddress =>
      _es ? 'Error al guardar dirección' : 'Failed to save address';
  String get failedToDelete => _es ? 'Error al eliminar' : 'Failed to delete';

  // ── Driver Promos (labels) ──
  String get surgeZonePromoDesc => _es
      ? '¡Alta demanda en tu zona! Gana más por viaje.'
      : 'High demand in your area! Earn more per trip.';
  String get consecutiveBonusPromoDesc => _es
      ? 'Completa 5 viajes seguidos y gana un bono.'
      : 'Complete 5 trips in a row and earn a bonus.';
  String get peakHoursBonusPromoDesc => _es
      ? 'Maneja entre 5PM–9PM y gana extra.'
      : 'Drive between 5PM–9PM and earn extra.';
  String get nightOwlBonusPromoDesc => _es
      ? 'Maneja entre 11PM–4AM y gana un bono.'
      : 'Drive between 11PM–4AM and earn a bonus.';
  String get weekendWarriorPromoDesc => _es
      ? 'Completa 20 viajes este fin de semana y gana un bono.'
      : 'Complete 20 trips this weekend and earn a bonus.';
  String get airportBonusPromoDesc => _es
      ? 'Gana \$2 extra en cada recogida de aeropuerto.'
      : 'Earn \$2 extra on every airport pickup.';
  String get referralBlitz => _es ? 'Blitz de Referidos' : 'Referral Blitz';
  String get referralBlitzDesc => _es
      ? 'Refiere un nuevo conductor y ambos ganan \$50.'
      : 'Refer a new driver and both earn \$50.';

  // ── Payout Methods ──
  String get completeStripeOnboarding => _es
      ? 'Completa la configuración de Stripe para activar tu cuenta bancaria.'
      : 'Complete Stripe onboarding to activate your bank account.';

  // ── Driver Info Pages ──
  String get keepVehicleSpotless =>
      _es ? 'Mantén tu vehículo impecable' : 'Keep Your Vehicle Spotless';
  String get firstImpressionsMatter =>
      _es ? 'Las primeras impresiones importan' : 'First impressions matter';
  String get cleanInsideOut =>
      _es ? 'Limpio por dentro y por fuera' : 'Clean Inside & Out';
  String get cleanInsideOutBody => _es
      ? 'Lava tu auto regularmente y mantén el interior limpio.'
      : 'Wash your car regularly and keep the interior clean.';
  String get freshComfortable =>
      _es ? 'Fresco y cómodo' : 'Fresh & Comfortable';
  String get freshComfortableBody => _es
      ? 'Mantén la cabina fresca con un aroma agradable.'
      : 'Keep the cabin fresh with a pleasant scent.';
  String get phoneMountCharger =>
      _es ? 'Soporte de teléfono y cargador' : 'Phone Mount & Charger';
  String get phoneMountChargerBody => _es
      ? 'Usa un soporte seguro para tu teléfono y ofrece cargador.'
      : 'Use a secure phone mount and offer a charger.';
  String get professionalAppearance =>
      _es ? 'Apariencia profesional' : 'Professional Appearance';
  String get professionalAppearanceBody => _es
      ? 'Vístete de forma presentable.'
      : 'Dress neatly and professionally.';
  String get driveSafeAlways =>
      _es ? 'Conduce seguro, siempre' : 'Drive Safe, Always';
  String get safetyPriority =>
      _es ? 'La seguridad es tu prioridad #1' : 'Safety is your #1 priority';
  String get obeyTrafficLaws =>
      _es ? 'Obedece las leyes de tránsito' : 'Obey Traffic Laws';
  String get obeyTrafficLawsBody => _es
      ? 'Respeta los límites de velocidad y señales de tránsito.'
      : 'Follow speed limits and traffic signs.';
  String get zeroTolerancePolicy =>
      _es ? 'Política de tolerancia cero' : 'Zero Tolerance Policy';
  String get zeroToleranceBody => _es
      ? 'Nunca conduzcas bajo la influencia del alcohol o drogas.'
      : 'Never drive under the influence of alcohol or drugs.';
  String get stayFocused => _es ? 'Mantente enfocado' : 'Stay Focused';
  String get stayFocusedBody => _es
      ? 'No envíes mensajes mientras conduces.'
      : 'No texting while driving.';
  String get seatbeltRequired =>
      _es ? 'Cinturón de seguridad obligatorio' : 'Seatbelt Required';
  String get seatbeltRequiredBody => _es
      ? 'Asegúrate de que todos los pasajeros usen el cinturón.'
      : 'Ensure all passengers wear their seatbelt.';
  String get deliver5StarService =>
      _es ? 'Brinda servicio 5 estrellas' : 'Deliver 5-Star Service';
  String get makeRideMemorableSubtitle =>
      _es ? 'Haz cada viaje memorable' : 'Make every ride memorable';
  String get greetEveryRider =>
      _es ? 'Saluda a cada pasajero' : 'Greet Every Rider';
  String get greetEveryRiderBody => _es
      ? 'Dale la bienvenida a los pasajeros por su nombre.'
      : 'Welcome riders by name.';
  String get efficientRoutes => _es ? 'Rutas eficientes' : 'Efficient Routes';
  String get efficientRoutesBody => _es
      ? 'Sigue la navegación GPS y toma la ruta más rápida.'
      : 'Follow GPS navigation and take the fastest route.';
  String get respectPreferences =>
      _es ? 'Respeta las preferencias' : 'Respect Preferences';
  String get respectPreferencesBody => _es
      ? 'Mantén la música baja y pregunta las preferencias.'
      : 'Keep music low and ask for preferences.';
  String get goExtraMile => _es ? 'Da un esfuerzo extra' : 'Go the Extra Mile';
  String get goExtraMileBody => _es
      ? 'Ayuda con el equipaje y ofrece una experiencia premium.'
      : 'Help with luggage and offer a premium experience.';

  // ── Signup ──
  /// Headings that split the driver's document checklist in two.
  /// Shown when nine digits are in but they cannot be an SSN.
  String get ssnNotPossible => _es
      ? 'Ese número no puede ser un Social Security Number. Revisa los dígitos.'
      : 'That cannot be a Social Security Number. Check the digits.';
  String get docsAboutYou => _es ? 'Sobre ti' : 'About you';
  String get docsAboutYourCar => _es ? 'Sobre tu auto' : 'About your car';
  String get carRegistration =>
      _es ? 'Registro del vehículo' : 'Car Registration';
  String get carRegistrationSubtitle => _es
      ? 'Toma o sube una foto de tu registro'
      : 'Take or upload a photo of your registration';

  // ── Scheduled rides ──
  String get claimedLabel => _es ? 'Reclamado' : 'Claimed';
  String get contactSupportToCancel =>
      _es ? 'Contacta soporte para cancelar' : 'Contact Support to cancel';
  String labelCopied(String label) => _es ? '$label copiado' : '$label copied';
  String get locationServicesDisabled => _es
      ? 'Servicios de ubicación desactivados'
      : 'Location services disabled';
  String get locationPermissionDenied =>
      _es ? 'Permiso de ubicación denegado' : 'Location permission denied';

  // ── Remaining hardcoded strings ───────────────────────────────────────────
  String get call911Assistance => _es
      ? 'Llama al 911 para asistencia inmediata'
      : 'Call 911 for immediate assistance';
  String get call911OrEmergency => _es
      ? 'Llama al 911 o servicios de emergencia'
      : 'Call 911 or emergency services';
  String get noPhoneNumberAvailable => _es
      ? 'No hay numero de telefono disponible'
      : 'No phone number available';
  String get thenDirection => _es ? 'Luego' : 'Then';
  String get backgroundCheckInitiated => _es
      ? 'Verificacion de antecedentes iniciada! Revisa tu email.'
      : 'Background check initiated! Check your email.';
  String failedToUpload(String title, String error) =>
      _es ? 'Error al subir $title: $error' : 'Failed to upload $title: $error';
  String get failedToSendCode => _es
      ? 'Error al enviar codigo. Intenta de nuevo.'
      : 'Failed to send code. Try again.';
  String get pleaseEnterFullCode => _es
      ? 'Por favor ingresa el codigo completo.'
      : 'Please enter the full code.';
  String get failedToResendCode => _es
      ? 'Error al reenviar. Intenta de nuevo.'
      : 'Failed to resend. Try again.';
  String get serverUrlSaved =>
      _es ? 'URL del servidor guardada' : 'Server URL saved';
  String get failedToSendCodeLogin => _es
      ? 'Error al enviar codigo. Intenta de nuevo.'
      : 'Failed to send code. Please try again.';
  String codeResentTo(String email) =>
      _es ? 'Codigo reenviado a $email' : 'Code resent to $email';
  String get noNotificationsYet =>
      _es ? 'Aun no hay notificaciones.' : 'No notifications yet.';
  String get typeToSearchForAddress => _es
      ? 'Escribe para buscar una direccion'
      : 'Type to search for an address';
  String get noMessagesInConversation => _es
      ? 'No hay mensajes en esta conversacion'
      : 'No messages in this conversation';
  String get failedToExportData => _es
      ? 'Error al exportar datos. Intenta de nuevo.'
      : 'Failed to export data. Please try again.';
  String get tripDidntHappenAnswer => _es
      ? 'Si te cobraron por un viaje que nunca se realizo, nos disculpamos por la inconveniencia.\n\n'
          'Esto puede pasar por:\n'
          '- Un conductor inicio el viaje accidentalmente\n'
          '- Errores de GPS\n'
          '- Fallas de la app\n\n'
          'Contacta a soporte e investigaremos y emitiremos un reembolso completo si se confirma.'
      : 'If you were charged for a ride that never took place, we apologize for the inconvenience.\n\n'
          'This can happen due to:\n'
          '\u2022 A driver starting the trip accidentally\n'
          '\u2022 GPS errors\n'
          '\u2022 App glitches\n\n'
          'Please contact support and we\'ll investigate and issue a full refund if confirmed.';
  String get payoutsConnected => _es ? 'Pagos conectados' : 'Payouts Connected';
  String rideForName(String name) =>
      _es ? 'Viaje para $name' : 'Ride for $name';
  String get consentRequired => _es
      ? 'Acepta el consentimiento para continuar'
      : 'Please accept the consent to proceed';
  String errorWithMessage(String error) =>
      _es ? 'Error: $error' : 'Error: $error';
  String emergencyAlertSentTo(int count) => _es
      ? 'Alerta de emergencia enviada a $count contacto${count > 1 ? 's' : ''}'
      : 'Emergency alert sent to $count contact${count > 1 ? 's' : ''}';

  // ── Missing keys added for full localization ──────────────────────────────
  String get quickAccessTitle => _es ? 'Acceso Rápido' : 'Quick Access';
  String get favoritesLabel => _es ? 'Favoritos' : 'Favorites';
  String get noFavoritePlacesMessage =>
      _es ? 'No tienes lugares guardados aún' : 'No favorite places saved yet';
  String get changeLabel => _es ? 'Cambiar' : 'Change';
  String get amLabel => 'AM';
  String get pmLabel => 'PM';
  String get tripIdLabel => _es ? 'ID de Viaje' : 'Trip ID';
  String get riderLabel => _es ? 'Pasajero' : 'Rider';
  String get vipTierLabel => 'VIP';
  String get premiumTierLabel => 'PREMIUM';
  String get comfortTierLabel => 'COMFORT';
  String get pickupAddressLabel =>
      _es ? 'Dirección de recogida' : 'Pickup address';
  String get dropoffAddressLabel =>
      _es ? 'Dirección de destino' : 'Dropoff address';
  String get noNewRidesUntilComplete => _es
      ? 'No recibirás nuevos viajes hasta completar este viaje reservado'
      : 'You won\'t receive new rides until this scheduled ride is completed';
  String get scheduledRideLabel => _es ? 'VIAJE RESERVADO' : 'SCHEDULED RIDE';
  String get pickupInLabel => _es ? 'Recogida en' : 'Pickup in';
  String get forPickup => _es ? 'para recogida' : 'until pickup';
  String get startRideButton => _es ? 'INICIAR VIAJE' : 'START RIDE';
  String get availableInLabel => _es ? 'DISPONIBLE EN' : 'AVAILABLE IN';
  String scheduledAvailableCount(int n) => _es
      ? (n == 1 ? '1 viaje disponible' : '$n viajes disponibles')
      : (n == 1 ? '1 ride available' : '$n rides available');

  // ── Vehicle page ──
  String get addVehicleAsk => _es
      ? 'Escríbele a soporte para agregar otro vehículo — hace falta revisar su registro y su seguro.'
      : 'Contact support to add another vehicle — its registration and insurance have to be reviewed.';
  String get seeDetails => _es ? 'Ver detalles' : 'See details';
  String get noVehicleOnFile =>
      _es ? 'Sin vehículo registrado' : 'No vehicle on file';
  String get availableRideTypes =>
      _es ? 'Tipos de viaje disponibles' : 'Available ride types';
  String get rideTypesSubject => _es
      ? 'Sujeto a la disponibilidad de tu zona.'
      : 'All ride types subject to availability in your region.';
  String get tierFromYourVehicle => _es
      ? 'Según el vehículo que tienes registrado'
      : 'From the vehicle on your account';
  String get manageCar => _es ? 'Gestionar vehículo' : 'Manage car';
  String get viewDocuments => _es ? 'Ver documentos' : 'View documents';
  String get removeVehicle => _es ? 'Quitar vehículo' : 'Remove vehicle';
  String get removeVehicleAsk => _es
      ? '¿Seguro? Perderías sus documentos y su categoría.'
      : 'Are you sure? Its documents and tier go with it.';
  String get removeVehicleContactSupport => _es
      ? 'Escríbele a soporte para quitar tu vehículo.'
      : 'Contact support to remove your vehicle.';

  String get scheduledRidesTitle =>
      _es ? 'Viajes Reservados' : 'Scheduled Rides';
  String get noScheduledTrips => _es
      ? 'No hay viajes reservados disponibles'
      : 'No scheduled rides available';
  String get scheduledTripsHint => _es
      ? 'Los viajes reservados por pasajeros aparecerán aquí'
      : 'Rides scheduled by riders will appear here';
  String get acceptRideButton => _es ? 'ACEPTAR VIAJE' : 'ACCEPT RIDE';
  String get availableLabel => _es ? 'Solicitudes' : 'Requests';
  String get myRidesLabel => _es ? 'Mis Reservas' : 'My Scheduled';
  String scheduledRidesAvailableLabel(int count) => _es
      ? '$count viaje${count == 1 ? '' : 's'} reservado${count == 1 ? '' : 's'} disponible${count == 1 ? '' : 's'}'
      : '$count scheduled ride${count == 1 ? '' : 's'} available near you';
  String get scheduledRideConfirmed =>
      _es ? 'Viaje reservado confirmado' : 'Scheduled ride confirmed';
  String get noScheduledRidesAvailable => _es
      ? 'No hay viajes reservados disponibles'
      : 'No scheduled rides available';
  String get cancelRideTitle => _es ? 'Cancelar viaje' : 'Cancel ride';
  String get cancelRideBody => _es
      ? 'El viaje volverá al marketplace y otro conductor podrá tomarlo.'
      : 'The ride will return to the marketplace and another driver can take it.';
  // Exact texts from the Shopify widget's __vrSearchMsgs rotation
  // (snippets-ride-request-airport.liquid:286).
  String get searchStatusMsg1 => _es ? 'Casi listo...' : 'Almost there...';
  String get searchStatusMsg2 =>
      _es ? 'Buscando tu chofer...' : 'Looking for your driver...';
  String get searchStatusMsg3 =>
      _es ? 'Buscando choferes cercanos...' : 'Searching nearby drivers...';
  String get searchStatusMsg4 => _es
      ? 'Conectándote con un viaje premium...'
      : 'Matching you with a premium ride...';

  // ── Driver Trip Accept Screen — new localization keys ─────────────────────
  String get fetchingAddress =>
      _es ? 'Obteniendo dirección...' : 'Getting address...';
  String get passengerConfirmedOnboard => _es
      ? 'El pasajero ha confirmado que está en tu vehículo'
      : 'Passenger confirmed they are in your vehicle';
  String newMessagesFromRider(int count) => _es
      ? '$count nuevo${count > 1 ? "s" : ""} mensaje${count > 1 ? "s" : ""} del pasajero'
      : '$count new message${count > 1 ? "s" : ""} from rider';
  // Safety sheet
  String get reportSafetyIssueTip =>
      _es ? 'Reportar problema de seguridad' : 'Report Safety Issue';
  String get reportSafetyIssueSubtitle => _es
      ? 'Reportar una preocupación de seguridad sobre este viaje'
      : 'Report a safety concern about this trip';
  String get shareMyLocationTip =>
      _es ? 'Compartir mi ubicación' : 'Share My Location';
  String get shareMyLocationSubtitle => _es
      ? 'Compartir viaje con un contacto de confianza'
      : 'Share trip with a trusted contact';
  String get problemWithPickup => _es
      ? 'Problema con dirección de recogida'
      : 'Problem with pickup address';
  String get problemWithPickupSubtitle => _es
      ? 'La ubicación de recogida es incorrecta o poco clara'
      : 'The pickup location is incorrect or unclear';
  String get problemWithDropoff => _es
      ? 'Problema con dirección de destino'
      : 'Problem with dropoff address';
  String get problemWithDropoffSubtitle => _es
      ? 'La ubicación de destino es incorrecta o poco clara'
      : 'The dropoff location is incorrect or unclear';
  String get problemWithTrip =>
      _es ? 'Problema con el viaje' : 'Problem with trip';
  String get problemWithTripSubtitle =>
      _es ? 'Otro problema con este viaje' : 'Other issue with this trip';
  String get contactSupportTip => _es ? 'Contactar soporte' : 'Contact Support';
  String get contactSupportSubtitle =>
      _es ? 'Hablar con un agente de soporte' : 'Speak with a support agent';
  // Cancellation reasons
  List<String> get pickupCancelReasons => _es
      ? [
          'La dirección es incorrecta',
          'No puedo encontrar el lugar',
          'El rider no está en la ubicación',
          'Otra razón'
        ]
      : [
          'The address is incorrect',
          "I can't find the place",
          'Rider is not at the location',
          'Other reason'
        ];
  List<String> get dropoffCancelReasons => _es
      ? [
          'La dirección es incorrecta',
          'No puedo llegar a ese lugar',
          'El destino no existe',
          'Otra razón'
        ]
      : [
          'The address is incorrect',
          "I can't get to that place",
          'The destination does not exist',
          'Other reason'
        ];
  List<String> get tripCancelReasons => _es
      ? [
          'El rider no aparece',
          'El rider canceló de forma inapropiada',
          'Problema de seguridad',
          'El viaje fue modificado sin mi consentimiento',
          'Otra razón'
        ]
      : [
          'Rider did not show up',
          'Rider cancelled inappropriately',
          'Safety concern',
          'The trip was modified without my consent',
          'Other reason'
        ];
  // Tooltip strings
  String get arrivedButtonTooltip => _es
      ? 'El botón se activa cuando ya estés en la dirección de pickup'
      : 'Button activates when you are at the pickup address';
  String get finishButtonTooltip => _es
      ? 'El botón se activa cuando ya estés en la dirección de destino'
      : 'Button activates when you are at the destination address';
  // Start trip button
  String get startingLabel => _es ? 'Iniciando...' : 'Starting...';
  String get startTripLabel => _es ? 'Iniciar Viaje' : 'Start Trip';
  String get startRideLabel => _es ? 'Iniciar Viaje' : 'Start Ride';
  // Message / Call action buttons
  String get messageAction => _es ? 'Mensaje' : 'Message';
  String get callAction => _es ? 'Llamar' : 'Call';

  // ── Scheduled Rides status badge extras ──────────────────────────────────
  String get rideConfirmed => _es ? 'Viaje Confirmado' : 'Ride Confirmed';
  String get pendingDriver => _es ? 'Conductor Pendiente' : 'Pending Driver';
  String get upcoming => _es ? 'Próximo' : 'Upcoming';

  // ── Rider Confirm Pickup Screen ────────────────────────────────────────────
  String get rideAutoStartWarning => _es
      ? 'El viaje comenzará automáticamente\nsi olvidaste confirmar'
      : 'The ride will start automatically\nif you forgot to confirm';

  // ── Scheduled Rides Screen (rider) ────────────────────────────────────────
  String get driverAssignedLabel =>
      _es ? 'Conductor Asignado' : 'Driver Assigned';

  // ── Referral Screen (remaining) ───────────────────────────────────────────
  String get giveGetTitle =>
      _es ? 'Da \$10, Recibe \$10' : 'Give \$10, Get \$10';
  String get shareCodeBannerSubtitle => _es
      ? 'Comparte tu código con amigos. Cuando se unan,\nambos ganan \$10.'
      : 'Share your code with friends. When they join,\nyou both earn \$10.';
  String shareInviteMessage(String code) => _es
      ? '¡Únete a Cruise! Usa mi código de referido $code cuando te registres y obtén \$10 de descuento en tu primer viaje. ¡Descarga la app ahora! 🚗✨'
      : 'Join me on Cruise! Use my referral code $code when you sign up and get \$10 off your first ride. Download the app now! 🚗✨';
  String get shareInviteSubject => _es
      ? '¡Únete a Cruise — obtén \$10 de descuento!'
      : 'Join Cruise — get \$10 off!';
  String get haveAFriendsCode =>
      _es ? '¿Tienes el código de un amigo?' : "Have a Friend's Code?";
  String get enterCodeHint => _es ? 'INGRESA EL CÓDIGO' : 'ENTER CODE';

  // ── Account Screen (remaining) ────────────────────────────────────────────
  String get emailVerificationTitle =>
      _es ? 'Verificación de Email' : 'Email Verification';
  String get emailVerificationDesc => _es
      ? 'Enviaremos un código de verificación a tu dirección de email.'
      : "We'll send a verification code to your email address.";
  String get enterCodeSentToEmail => _es
      ? 'Ingresa el código enviado a tu email:'
      : 'Enter the code sent to your email:';
  String get verificationFailed => _es
      ? 'Verificación fallida. Intenta de nuevo.'
      : 'Verification failed. Try again.';
  String get verificationFailedName => _es
      ? 'No hemos podido verificar tu identidad. Ingresa una identificación que coincida con el nombre y apellido de tu cuenta.'
      : 'We could not verify your identity. Please provide an ID that matches the first and last name on your account.';
  String get placeLabel => _es ? 'Lugar' : 'Place';
  String addLabelFor(String label) => _es ? 'Agregar $label' : 'Add $label';
  String setLabelAddress(String label) =>
      _es ? 'Establecer dirección de $label' : 'Set $label address';

  // ── Schedule Picker Sheet (remaining) ─────────────────────────────────────
  String get selectTimeTitle => _es ? 'Seleccionar hora' : 'Select Time';
  String get pickPreferredTime =>
      _es ? 'Elige tu hora preferida' : 'Pick your preferred time';
  String get chooseDateForRide =>
      _es ? 'Elige una fecha para tu viaje' : 'Choose a date for your ride';
  String get airportTripLabel => _es ? 'Viaje al aeropuerto' : 'Airport trip';
  String get confirmAndBook => _es ? 'Confirmar y Reservar' : 'Confirm & Book';

  // ── Pickup/Dropoff Search Screen (locpicker) ─────────────────────────────
  String get dropPinAtExactSpot => _es
      ? 'Coloca un pin en tu punto exacto'
      : 'Drop a pin at your exact spot';
  String get savedPlaces => _es ? 'Lugares guardados' : 'Saved places';
  String get recentLabel => _es ? 'Recientes' : 'Recent';
  String get enterPickupAddress =>
      _es ? 'Ingresa la dirección de origen' : 'Enter pickup address';
  String get moveMapToSetDropoff => _es
      ? 'Mueve el mapa para elegir destino'
      : 'Move map to set dropoff location';
  String get moveMapToSetPickup => _es
      ? 'Mueve el mapa para elegir origen'
      : 'Move map to set pickup location';
  String get setYourDropoff => _es ? 'Define tu destino' : 'Set your drop-off';
  String get setYourPickup => _es ? 'Define tu origen' : 'Set your pickup';
  String get moveMapToPreferredDropoff => _es
      ? 'Mueve el mapa hasta tu punto preferido de destino.'
      : 'Move map to your preferred drop-off location.';
  String get moveMapToPreferredPickup => _es
      ? 'Mueve el mapa hasta tu punto preferido de origen.'
      : 'Move map to your preferred pickup location.';
  String get locationCaps => _es ? 'UBICACIÓN' : 'LOCATION';
  String get cardPaymentLabel =>
      _es ? 'Tarjeta Débito / Crédito' : 'Debit/Credit Card';
  String get testModeLabel => _es ? 'Modo de Prueba' : 'Test Mode';
  String get simulatePayment => _es ? 'Simular pago' : 'Simulate payment';

  // ── Login Screen ──────────────────────────────────────────────────────────
  String get googleSignInCancelled => _es
      ? 'Inicio de sesión con Google cancelado'
      : 'Google Sign In was cancelled';
  String get googleNoEmail => _es
      ? 'No se pudo obtener el email de Google. Intenta de nuevo.'
      : 'Could not get email from Google. Please try again.';
  String googleSignInError(String e) => _es
      ? 'Error de inicio de sesión con Google: $e'
      : 'Google Sign In error: $e';
  String get appleSignInCancelled => _es
      ? 'Inicio de sesión con Apple cancelado'
      : 'Apple Sign In was cancelled';
  String appleSignInError(String e) => _es
      ? 'Error de inicio de sesión con Apple: $e'
      : 'Apple Sign In error: $e';
  String get failedToSendVerificationCode => _es
      ? 'Error al enviar código de verificación. Intenta de nuevo.'
      : 'Failed to send verification code. Please try again.';
  String failedToSendVerificationCodeError(String e) => _es
      ? 'Error al enviar código de verificación: $e'
      : 'Failed to send verification code: $e';
  String providerCredentialsRejected(String provider) => _es
      ? 'Credenciales de $provider rechazadas. Intenta de nuevo.'
      : '$provider credentials rejected. Please try again.';
  String registrationFailedWith(String e) =>
      _es ? 'Registro fallido: $e' : 'Registration failed: $e';
  String get enterYourEmailTitle =>
      _es ? 'Ingresa tu Email' : 'Enter Your Email';
  String get appleEmailExplanation => _es
      ? 'Apple no compartió tu email esta vez. Ingresa el email vinculado a tu Apple ID.'
      : 'Apple did not share your email this time. Please enter the email address linked to your Apple ID.';
  String accountAlreadyRegistered(String method) => _es
      ? 'Ya existe una cuenta con este $method. ¿Deseas iniciar sesión?'
      : 'An account with this $method is already registered. Would you like to log in instead?';
  String get logInBtn => _es ? 'Iniciar Sesión' : 'Log In';
  String get createAccountTitle => _es ? 'Crear cuenta' : 'Create account';
  String get createAccountSubtitle => _es
      ? 'Ingresa tus datos para registrarte.'
      : 'Enter your details to sign up.';
  String get acceptTermsDocuments => _es
      ? 'He leído y acepto los Términos de Servicio y todos los documentos legales.'
      : 'I have read and accept the Terms of Service and all legal documents.';
  String get acceptPrivacyData => _es
      ? 'Acepto la Política de Privacidad y el tratamiento de mis datos personales.'
      : 'I accept the Privacy Policy and the processing of my personal data.';
  String get enterPhoneToSignUp => _es
      ? 'Ingresa tu número de teléfono para registrarte.'
      : 'Enter your phone number to sign up.';
  String get enterEmailToSignUp => _es
      ? 'Ingresa tu email para registrarte.'
      : 'Enter your email to sign up.';
  String get emailAddressHint => _es ? 'Dirección de email' : 'Email address';
  String get continueWithPhone =>
      _es ? 'Continuar con Teléfono' : 'Continue with Phone';
  String get continueWithEmail =>
      _es ? 'Continuar con Email' : 'Continue with Email';
  String get continueWithGoogle =>
      _es ? 'Continuar con Google' : 'Continue with Google';
  String get continueWithApple =>
      _es ? 'Continuar con Apple' : 'Continue with Apple';
  String get signInBtn => _es ? 'Iniciar sesión' : 'Sign in';
  String get byContinuingAgree => _es
      ? 'Al continuar, aceptas nuestros '
      : 'By continuing, you agree to our ';
  String get termsLink => _es ? 'Términos' : 'Terms';
  String get andConjunction => _es ? ' y ' : ' and ';
  String get privacyPolicyLink =>
      _es ? 'Política de Privacidad' : 'Privacy Policy';

  // ── Login Password Screen ─────────────────────────────────────────────────
  String get invalidCredentialsNoAccount => _es
      ? 'Credenciales inválidas. No se encontró cuenta con este email.'
      : 'Invalid credentials. No account found with this email.';
  String get googleSignInFailed => _es
      ? 'Inicio de sesión con Google falló. Intenta de nuevo.'
      : 'Google sign-in failed. Please try again.';
  String get appleSignInFailed => _es
      ? 'Inicio de sesión con Apple falló. Intenta de nuevo.'
      : 'Apple sign-in failed. Please try again.';
  String get couldNotSendVerificationEmail => _es
      ? 'No se pudo enviar el email de verificación. Intenta de nuevo.'
      : 'Could not send verification email. Please try again.';
  String get whereToSendCode => _es
      ? '¿Dónde enviaremos tu\ncódigo de verificación?'
      : 'Where should we send\nyour verification code?';
  String get textMessageSms =>
      _es ? 'Mensaje de texto (SMS)' : 'Text message (SMS)';
  String get noContactMethodAvailable => _es
      ? 'No hay método de contacto disponible'
      : 'No contact method available';
  String get deviceClockOutOfSync => _es
      ? 'Reloj del dispositivo desincronizado. Ve a Ajustes → Fecha y Hora y activa "Ajustar automáticamente".'
      : 'Device clock out of sync. Go to Settings → Date & Time and enable "Set Automatically".';
  String get invalidEmailPhoneOrPassword => _es
      ? 'El correo/teléfono o la contraseña que ingresaste son incorrectos'
      : 'The email/phone or password you entered is incorrect';
  String get accountNoLongerExists =>
      _es ? 'Esta cuenta ya no existe' : 'This account no longer exists';
  String get orLower => _es ? 'o' : 'or';
  String get signInWithGoogle =>
      _es ? 'Iniciar sesión con Google' : 'Sign in with Google';
  String get signInWithApple =>
      _es ? 'Iniciar sesión con Apple' : 'Sign in with Apple';

  // ── Trip Receipt Screen ───────────────────────────────────────────────────
  String receiptSentToEmail(String email) =>
      _es ? 'Recibo enviado a $email' : 'Receipt sent to $email';
  String completedOnDate(String date) =>
      _es ? 'Completado · $date' : 'Completed · $date';
  String get tripDetailsHeader => _es ? 'Detalles del Viaje' : 'Trip Details';
  String get fareBreakdownHeader => _es ? 'Resumen de Pago' : 'Payment Summary';
  String get baseFareLabel => _es ? 'Tarifa base' : 'Base fare';
  String mileageLabel(String dist) =>
      _es ? 'Distancia ($dist)' : 'Mileage ($dist)';
  String timeFareLabel(String time) => _es ? 'Tiempo ($time)' : 'Time ($time)';
  String surgeLabel(String mult) => _es ? 'Recargo ($mult)' : 'Surge ($mult)';
  String waitTimeLabel(String time) =>
      _es ? 'Tiempo de espera ($time)' : 'Wait time ($time)';
  String get routeHeader => _es ? 'Ruta' : 'Route';
  String get pickupTagLabel => _es ? 'RECOGIDA' : 'PICKUP';
  String get dropoffTagLabel => _es ? 'DESTINO' : 'DROP-OFF';
  String get shareBtn => _es ? 'Compartir' : 'Share';
  String get sentLabel => _es ? 'Enviado' : 'Sent';
  String get thankYouForRiding => _es
      ? 'Gracias por viajar con Cruise'
      : 'Thank you for riding with Cruise';
  String get paidByPassengerLabel =>
      _es ? 'Pagado por el pasajero' : 'Paid by passenger';
  String get subtotalLabel => 'Subtotal';
  String get scheduledFeeLabel =>
      _es ? 'Cargo por viaje programado' : 'Scheduled ride fee';
  String get meetGreetLabel => 'Meet & Greet';
  String get cancellationFeeLabel =>
      _es ? 'Cargo por cancelación' : 'Cancellation fee';
  String get floridaTaxLabel => _es ? 'Impuesto' : 'Tax';
  String get tripFareLabel => _es ? 'Tarifa del viaje' : 'Trip fare';
  String get noTipLabel => _es ? 'Sin propina' : 'No tip';

  // ── Emergency Dialog (driver) ─────────────────────────────────────────────
  String get emergencyHelpTitle =>
      _es ? '¿Necesitas ayuda de emergencia?' : 'Need emergency help?';

  // ── Cancel / Confirm Overlay (rider tracking) ────────────────────────────
  String get cancellingTrip =>
      _es ? 'Cancelando viaje...' : 'Cancelling trip...';
  String get findAnotherRide => _es ? 'Buscar otro ride' : 'Find another ride';

  // ── Rider Confirm Pickup Screen (additional) ─────────────────────────────
  String get tripConfirmedExclaim =>
      _es ? '¡Viaje confirmado!' : 'Trip confirmed!';
  String get yourDriverHasArrived =>
      _es ? 'Tu conductor ha llegado' : 'Your driver has arrived';
  String driverIsWaiting(String name) =>
      _es ? '$name está esperando' : '$name is waiting';
  String get pressWhenWithDriver => _es
      ? 'Presiona cuando\nestés con el driver'
      : 'Press when you\nare with the driver';
  String get isWaiting => _es ? 'está esperando' : 'is waiting';
  String get driverDetected => _es ? 'Driver detectado' : 'Driver detected';
  String get finding => _es ? 'BUSCANDO' : 'FINDING';
  String get followArrowToDriver => _es
      ? 'Sigue la flecha para\nencontrar a tu driver'
      : 'Follow the arrow to\nfind your driver';
  String get freeWaitTime => _es ? 'Tiempo de espera gratis' : 'Free wait time';
  String get rideStartsAutomatically => _es
      ? 'El viaje comenzará automáticamente si olvidaste confirmar'
      : 'The ride will start automatically if you forgot to confirm';
  String get yourTripConfirmed =>
      _es ? 'Tu viaje\nconfirmado' : 'Your trip\nconfirmed';

  // ── Driver offer card badges (2026-04-11 stack-of-badges policy) ─
  // Each badge is a single short label that can stack with the others
  // in a Wrap. Used by driver_online_widgets._buildOfferBadge.
  // Examples shown on the offer card:
  //   immediate, card    →  (no badges)
  //   immediate, cash    →  [PAGO EN EFECTIVO]
  //   scheduled, card    →  [RESERVADO]
  //   scheduled, cash    →  [RESERVADO]  [EFECTIVO]
  //   scheduled, airport →  [RESERVADO]  [AEROPUERTO]
  //   scheduled, airport+cash → [RESERVADO]  [AEROPUERTO]  [EFECTIVO]
  String get badgeReserved => _es ? 'RESERVADO' : 'RESERVED';
  String get badgeAirport => _es ? 'AEROPUERTO' : 'AIRPORT';
  String get badgeCash => _es ? 'EFECTIVO' : 'CASH';
  // Used standalone on immediate cash trips (slightly longer label
  // because there are no other badges next to it).
  String get badgeCashRide => _es ? 'PAGO EN EFECTIVO' : 'CASH RIDE';

  // Driver toast when a trip is cancelled remotely (dispatch / auto).
  String get driverTripCancelledReturning => _es
      ? 'Viaje cancelado. Volviendo a las ofertas.'
      : 'Trip cancelled. Returning to ride requests.';

  // Rider gold-snackbar messages used by the auto-cancel flow.
  String get riderNoDriversFoundTryAgain => _es
      ? 'No encontramos un conductor disponible. Intenta de nuevo.'
      : "We couldn't find a driver in time. Please try again.";

  // Rider instant-cancel flow: the confirmation body lives in
  // cancelAfterAssignBody (near line 1190); success shows the cancel
  // overlay's tripCancelled string.

  // Driver scheduled-rides "Release this ride" strings.
  String get releaseRideButton =>
      _es ? 'Liberar este viaje' : 'Release this ride';
  String get releaseRideTitle =>
      _es ? '¿Liberar este viaje reservado?' : 'Release this scheduled ride?';
  String get releaseRideBody => _es
      ? 'El viaje volverá al marketplace para que otro conductor lo tome. Esto NO cancela el viaje del rider.'
      : 'The ride will go back to the marketplace so another driver can pick it up. This does not cancel the trip for the rider.';
  String get releaseRideKeep => _es ? 'Mantener' : 'Keep';
  String get releaseRideConfirm => _es ? 'Liberar' : 'Release';
  String get releaseRideOk => _es
      ? 'Viaje liberado. Ya está en el marketplace.'
      : 'Ride released. It is back in the marketplace.';
  String get releaseRideError => _es
      ? 'No se pudo liberar el viaje. Intenta de nuevo.'
      : 'Could not release the ride. Please try again.';

  // ── Scheduled-time format helpers (driver offer card + offers screen) ─
  // The "Hoy a las HH:MM (ahora)" / "Today at HH:MM (now)" labels live
  // here so the driver app shows them in the phone's language. Use
  // schedTimeNow / schedTimeInMinutes / schedTimeInHours / schedTimeFutureDay
  // by passing the already-12-hour-formatted time string and the deltas.
  String schedTimeNow(String timeStr) =>
      _es ? 'Hoy a las $timeStr (ahora)' : 'Today at $timeStr (now)';
  String schedTimeInMinutes(String timeStr, int minutes) => _es
      ? 'Hoy a las $timeStr (en $minutes min)'
      : 'Today at $timeStr (in $minutes min)';
  String schedTimeInHours(String timeStr, int hours, int extraMinutes) => _es
      ? 'Hoy a las $timeStr (en ${hours}h ${extraMinutes}m)'
      : 'Today at $timeStr (in ${hours}h ${extraMinutes}m)';
  String schedTimeFutureDay(int day, int monthIndex0, String timeStr) {
    const monthsEs = [
      'Ene',
      'Feb',
      'Mar',
      'Abr',
      'May',
      'Jun',
      'Jul',
      'Ago',
      'Sep',
      'Oct',
      'Nov',
      'Dic',
    ];
    const monthsEn = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final m = (_es ? monthsEs : monthsEn)[monthIndex0];
    return _es ? '$day $m a las $timeStr' : '$m $day at $timeStr';
  }

  // Driver offer card — rider quality labels.
  String get newRiderLabel => _es ? 'Nuevo rider' : 'New rider';

  String get findingYouAnotherDriver =>
      _es ? 'Buscando otro conductor…' : 'Finding you another driver…';
  String get yourPickupIsUnchanged => _es
      ? 'Tu punto de recogida no cambia.'
      : 'Your pickup spot has not changed.';

  // Rider tracking — the assigned driver handed the trip back to dispatch.
  String get lookingForAnotherDriver => _es
      ? 'Tu conductor no pudo tomar el viaje. Buscando otro para ti…'
      : 'Your driver could not take the trip. Finding you another one…';

  // Support chat — label above the quick-reply topic pills.
  String get chooseATopic => _es ? 'ELIGE UN TEMA' : 'CHOOSE A TOPIC';

  // Rider tracking — support menu on the driver card.
  String get call911 => _es ? 'Llamar al 911' : 'Call 911';
  String get changeDestination =>
      _es ? 'Cambiar destino' : 'Change destination';
  String get changeDestinationViaSupport => _es
      ? 'Soporte cambiará tu destino y avisará al conductor.'
      : 'Support will change your destination and tell the driver.';
  String get trackMyCruiseRideLive =>
      _es ? 'Sigue mi viaje de Cruise en vivo:' : 'Track my Cruise ride live:';

  // Driver trip screen — header menu subtitles.
  String get backToDriverHomeSubtitle =>
      _es ? 'Volver a la pantalla principal' : 'Back to the main screen';
  String get driverMenuSubtitle =>
      _es ? 'Perfil, nivel y ajustes' : 'Profile, level and settings';
  String get earningsMenuSubtitle =>
      _es ? 'Ver tus ganancias del día' : 'See today\'s earnings';
  String get helpMenuSubtitle =>
      _es ? 'Problemas con el viaje o soporte' : 'Trip problems or support';
  String get cancelTripMenuSubtitle => _es
      ? 'Solo antes de recoger al pasajero'
      : 'Only before picking up the rider';

  // Driver "trip accepted" celebration overlay.
  String get tripAcceptedTitle => _es ? 'Viaje Aceptado' : 'Trip Accepted';
  String riderIsWaiting(String firstName) =>
      _es ? '$firstName está esperando' : '$firstName is waiting';

  // Shown when the driver app could not take the trip it had just been
  // assigned, so the trip was handed back to dispatch for another driver.
  String get tripReturnedToDispatch => _es
      ? 'No pudimos abrir el viaje. Lo devolvimos a despacho.'
      : "We couldn't open the trip. It went back to dispatch.";

  // Generic fallback labels used by offer cards when the trip payload
  // is missing addresses or names. These are visible in the offer
  // notifications, so they need to be localised.
  String get pickupFallback => _es ? 'Recogida' : 'Pickup';
  String get dropoffFallback => _es ? 'Destino' : 'Drop-off';
  String get riderFallback => _es ? 'Rider' : 'Rider';

  // Trip-share error snackbar with the underlying error appended.
  String couldNotShareTripError(String error) => _es
      ? 'No se pudo compartir el viaje: $error'
      : 'Could not share trip: $error';

  // notLoggedIn / navigateToPickup already defined further up in the
  // scheduled-trips strings block (around line 1362). Do not redeclare.

  // Cancel-failure snackbars from the rider waiting/tracking flow.
  String get cancelTripCheckConnection => _es
      ? 'No se pudo cancelar — revisa tu conexión.'
      : 'Could not cancel — check your connection.';
  String get cancelOnServerFailedActive => _es
      ? 'No se pudo cancelar en el servidor — el viaje puede seguir activo.'
      : 'Could not cancel on server — trip may still be active.';
  String get cancelRequestRetryBackground => _es
      ? 'La solicitud de cancelación puede no haber llegado al servidor — reintentaremos en segundo plano.'
      : 'Cancel request may not have reached the server — we will retry in the background.';

  // ── Driver pre-pickup cancel (accepted trip, before rider boards) ──────
  // Reason labels shown in the cancel bottom sheet; the machine strings
  // sent to the API live in driver_trip_accept_screen.dart.
  String get driverCancelReasonTitle =>
      _es ? '¿Por qué cancelas el viaje?' : 'Why are you cancelling?';
  String get driverCancelReasonVehicleIssue =>
      _es ? 'Problema con el vehículo' : 'Vehicle issue';
  String get driverCancelReasonRiderUnreachable =>
      _es ? 'No puedo contactar al pasajero' : 'Rider unreachable';
  String get driverCancelReasonSafety =>
      _es ? 'Preocupación de seguridad' : 'Safety concern';
  String get driverCancelReasonWrongPickup =>
      _es ? 'Ubicación de recogida incorrecta' : 'Wrong pickup location';
  String get driverCancelConfirmTitle =>
      _es ? '¿Cancelar este viaje?' : 'Cancel this trip?';
  String get driverCancelConfirmBody => _es
      ? 'El viaje volverá al marketplace y se buscará otro conductor para el pasajero.'
      : 'The trip will return to the marketplace and another driver will be matched for the rider.';
  String get driverCancelConfirmButton =>
      _es ? 'Sí, cancelar viaje' : 'Yes, cancel trip';
  String get driverCancellingLabel => _es ? 'Cancelando...' : 'Cancelling...';
  String get driverCancelRiderAboard => _es
      ? 'El pasajero ya está a bordo — usa el flujo de finalizar viaje.'
      : 'The rider is already aboard — use the end-ride flow instead.';
  String get driverCancelFailed =>
      _es ? 'No se pudo cancelar el viaje' : 'Could not cancel the trip';

  // ── Cancel-code → user-friendly localized message ──────────────
  // Used by the rider UI to translate the canonical `cancelCode`
  // field on RiderTripState into a phrase the rider can read in
  // their phone language. Falls back to the raw `rawReason` (or a
  // generic message) when the code isn't recognised.
  //
  // Codes are intentionally string literals so this stays
  // independent of the rider_trip_controller import.
  String cancelCodeMessage(String? code, {String? rawReason}) {
    switch (code) {
      case 'auto:no_driver_found_10min':
        return _es
            ? 'No encontramos un conductor disponible. Intenta de nuevo.'
            : "We couldn't find a driver in time. Please try again.";
      case 'auto:scheduled_no_driver_30min':
        return _es
            ? 'No hubo conductor para tu viaje reservado. Reserva nuevamente.'
            : 'No driver was available for your scheduled ride. Please book again.';
      case 'auto:guardian_ghost_stale':
        return _es
            ? 'Tu viaje fue detenido por el sistema. Contacta a soporte.'
            : 'Your trip was stopped by the system. Please contact support.';
      case 'client:no_internet':
        return _es
            ? 'Sin conexión a internet. Revisa tu red e intenta de nuevo.'
            : 'No internet connection. Check your network and try again.';
      case 'client:no_session':
        return _es
            ? 'No pudimos verificar tu sesión. Intenta de nuevo.'
            : 'Could not verify your session. Please try again.';
      case 'client:create_failed':
        return _es
            ? 'No se pudo crear el viaje. Intenta de nuevo.'
            : 'Could not create the trip. Please try again.';
      case 'client:connection_error':
        return _es
            ? 'Error de conexión. Revisa tu red e intenta de nuevo.'
            : 'Connection error. Check your network and try again.';
      case 'client:payment_declined':
        return _es
            ? 'Tu pago fue rechazado. Revisa tu método de pago e intenta de nuevo.'
            : 'Your payment was declined. Check your payment method and try again.';
      default:
        if (rawReason != null && rawReason.isNotEmpty) return rawReason;
        return _es ? 'Tu viaje fue cancelado.' : 'Your trip was cancelled.';
    }
  }
}

class _SDelegate extends LocalizationsDelegate<S> {
  const _SDelegate();

  @override
  bool isSupported(Locale locale) => ['en', 'es'].contains(locale.languageCode);

  @override
  Future<S> load(Locale locale) async => S(locale);

  @override
  bool shouldReload(covariant LocalizationsDelegate<S> old) => false;
}
