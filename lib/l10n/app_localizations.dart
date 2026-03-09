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

  // ── General / Shared ──────────────────────────────────────────────────────
  String get appName => 'Cruise';
  String get continueButton => _es ? 'Continuar' : 'Continue';
  String get next => _es ? 'Siguiente' : 'Next';
  String get skip => _es ? 'Saltar' : 'Skip';
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

  // ── Edit Profile ──────────────────────────────────────────────────────────
  String get changePhoto => _es ? 'Cambiar Foto' : 'Change Photo';
  String get saveChanges => _es ? 'Guardar Cambios' : 'Save Changes';
  String get firstNameRequired =>
      _es ? 'El nombre es requerido' : 'First name is required';
  String get phone => _es ? 'Teléfono' : 'Phone';

  // ── Safety Screen ─────────────────────────────────────────────────────────
  String get safetyTitle => _es ? 'Seguridad' : 'Safety';
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
  String get audioRecording => _es ? 'Grabación de Audio' : 'Audio recording';
  String get audioRecordingDesc => _es
      ? 'Graba audio durante tu viaje para mayor tranquilidad.'
      : 'Record audio during your trip for added peace of mind.';
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
  String get copyright => '© 2026 Cruise Technologies, Inc.';
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

  // ── Inbox ─────────────────────────────────────────────────────────────────
  String get inbox => _es ? 'Bandeja de Entrada' : 'Inbox';
  String get messages => _es ? 'Mensajes' : 'Messages';

  // ── Forgot Password ───────────────────────────────────────────────────────
  String get forgotPasswordTitle =>
      _es ? '¿Olvidaste tu contraseña?' : 'Forgot password?';
  String get resetPassword => _es ? 'Restablecer contraseña' : 'Reset password';
  String get forgotSubtitle => _es
      ? 'Introduce tu correo o teléfono para recibir un código de restablecimiento.'
      : "Enter your email or phone and we'll send you a reset code.";
  String get resetCodeSubtitle => _es
      ? 'Introduce el código de 6 dígitos que te enviamos y tu nueva contraseña.'
      : 'Enter the 6-digit code we sent and your new password.';
  String get sendCode => _es ? 'Enviar Código' : 'Send code';
  String get resendCode => _es ? 'Reenviar código' : 'Resend code';
  String get newPassword => _es ? 'Nueva contraseña' : 'New password';
  String get resetPasswordBtn =>
      _es ? 'Restablecer contraseña' : 'Reset password';
  String get resetSuccess => _es
      ? 'Contraseña restablecida exitosamente. Por favor inicia sesión.'
      : 'Password reset successfully. Please sign in.';

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
  String get tripsLabel => _es ? 'Viajes' : 'Trips';
  String get onlineLabel => _es ? 'En Línea' : 'Online';
  String get recommendedForYou =>
      _es ? 'Recomendado para ti' : 'Recommended for you';
  String get earningsToday => _es ? 'Ganancias de Hoy' : "Today's Earnings";
  String get tripsToday => _es ? 'Viajes Hoy' : 'Trips Today';
  String get hoursOnline => _es ? 'Horas en Línea' : 'Hours Online';
  String get findingTrips => _es ? 'Buscando viajes' : 'Finding trips';
  String get tripRequest => _es ? 'Solicitud de Viaje' : 'Trip Request';
  String get accept => _es ? 'Aceptar' : 'Accept';
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
  String get fastRide => _es ? 'Viaje Rápido' : 'Fast ride';
  String get schedule => _es ? 'Programar' : 'Schedule';
  String get recentActivity => _es ? 'Actividad Reciente' : 'Recent Activity';
  String get noServiceState => _es
      ? 'No hay servicios disponibles en tu estado actualmente.'
      : 'No services available in your state at this time.';
  String get understood => _es ? 'Entendido' : 'OK';
  String get fastRideUnavailable => _es
      ? 'Viaje rápido no está disponible cuando no hay conductores conectados cerca. Intenta de nuevo en unos minutos.'
      : 'Fast Ride is only available when there are drivers connected nearby. Please try again in a few minutes.';
  String get fastRideUnavailableTitle =>
      _es ? 'Viaje Rápido No Disponible' : 'Fast Ride Unavailable';
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

  // ── Login Verify ──────────────────────────────────────────────────────────
  String get connectionError => _es ? 'Error de conexión' : 'Connection error';
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
  String get minLabel => _es ? 'MIN' : 'MIN';
  String get yourDriverArrived =>
      _es ? 'Tu conductor ha llegado' : 'Your driver has arrived';
  String get yourDriverArrivedExcl =>
      _es ? '¡Tu conductor ha llegado!' : 'Your driver has arrived!';
  String driverWaitingAt(String firstName, String color, String model) => _es
      ? '$firstName te espera en el punto de recogida en un $color $model.'
      : '$firstName is waiting at the pickup spot in a $color $model.';
  String get onTripToDestination =>
      _es ? 'En viaje al destino' : 'On trip to destination';
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
      ? 'Protegido por Plaid — cifrado bancario. Cruise nunca ve tus credenciales.'
      : 'Secured by Plaid — bank-level encryption. Cruise never sees your login credentials.';
  String get noPayoutMethods =>
      _es ? 'Sin métodos de pago' : 'No payout methods';
  String get connectBankPrompt => _es
      ? 'Conecta tu cuenta bancaria con Plaid\npara retiros instantáneos'
      : 'Connect your bank account with Plaid\nfor instant cashouts';
  String get poweredByPlaid => _es ? 'Powered by Plaid' : 'Powered by Plaid';
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
  String get debitCardAdded => _es
      ? 'Tarjeta de débito agregada — retiro instantáneo habilitado'
      : 'Debit card added — instant cashout enabled';
  String get bankAccountLinked =>
      _es ? 'Cuenta bancaria vinculada' : 'Bank account linked';
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

  // ── Pickup/Dropoff Search Screen ───────────────────────────────────────────
  String get pickupLocationHint =>
      _es ? 'Lugar de recogida' : 'Pickup location';
  String get whereToHint => _es ? '¿A dónde vas?' : 'Where to?';
  String get setHomeAddress =>
      _es ? 'Establece tu dirección de casa' : 'Set your home address';
  String get setWorkAddress =>
      _es ? 'Establece tu dirección de trabajo' : 'Set your work address';
  String get chooseOnMap => _es ? 'Elegir en el mapa' : 'Choose on map';
  String setAddressTitle(String place) =>
      _es ? 'Establecer dirección de $place' : 'Set $place address';

  // ── Ride Request / Schedule Booking Screens ────────────────────────────────
  String get nowLabel => _es ? 'Ahora' : 'Now';
  String get scheduleLabel => _es ? 'Programar' : 'Schedule';
  String get chooseARide => _es ? 'Elige un viaje' : 'Choose a ride';
  String get bestBadge => _es ? 'MEJOR' : 'BEST';
  String get premiumBadge => 'PREMIUM';
  String get economyBadge => _es ? 'ECONÓMICO' : 'ECONOMY';
  String get comfortBadge => 'COMFORT';
  String get estFare => _es ? 'tarifa est.' : 'est. fare';
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
  String get currentPosition => _es ? 'Posición actual' : 'Current position';
  String get pickupLabel => _es ? 'Recogida' : 'Pickup';
  String get dropOffLabel => _es ? 'Destino' : 'Drop-off';
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
  String get headToPickup =>
      _es ? 'Dirígete al punto de recogida' : 'Head to pickup';
  String get headToDropOff =>
      _es ? 'Dirígete al punto de entrega' : 'Head to drop-off';
  String get headToDestination =>
      _es ? 'Dirígete al destino' : 'Head to destination';
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

  // ── Driver Offers Screen ───────────────────────────────────────────────────
  String get goOfflineBtn => _es ? 'Desconectarse' : 'Go Offline';
  String get onlineStatus => 'ONLINE';
  String get acceptingRide => _es ? 'Aceptando viaje...' : 'Accepting ride...';
  String get findingRidesNearYou =>
      _es ? 'Buscando viajes cerca de ti...' : 'Finding rides near you...';
  String get lookingForRides =>
      _es ? 'Buscando viajes...' : 'Looking for rides...';
  String get newOffersWillAppear => _es
      ? 'Los nuevos viajes aparecerán aquí automáticamente'
      : 'New offers will appear here automatically';
  String get availableRides => _es ? 'Viajes disponibles' : 'Available Rides';
  String get skipOffer => 'SKIP';
  String get acceptOffer => _es ? 'ACEPTAR' : 'ACCEPT';

  // ── Ride Request Screen ────────────────────────────────────────────────────
  String get tripCancelled => _es ? 'Viaje cancelado' : 'Trip cancelled';
  String get okBtn => _es ? 'Aceptar' : 'OK';
  String get fastRideLabel => _es ? 'Viaje rápido' : 'Fast Ride';
  String requestRideWithPrice(String price) =>
      _es ? 'Solicitar viaje · \$$price' : 'Request Ride · \$$price';
  String get requestRide => _es ? 'Solicitar viaje' : 'Request Ride';
  String get premiumTier => 'PREMIUM';
  String get economyTier => 'ECONOMY';
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
  String get cancelRideMsg => _es
      ? '¿Estás seguro de que quieres cancelar tu solicitud de viaje?'
      : 'Are you sure you want to cancel your ride request?';
  String get keepWaiting => _es ? 'Seguir esperando' : 'Keep Waiting';
  String get yesCancelBtn => _es ? 'Sí, cancelar' : 'Yes, Cancel';
  String get destination => _es ? 'Destino' : 'Destination';

  // ── Pickup/Dropoff Search Screen ───────────────────────────────────────────
  String get whereTo => _es ? '¿A dónde?' : 'Where to?';
  String get homeLabel => _es ? 'Casa' : 'Home';
  String get workLabel => _es ? 'Trabajo' : 'Work';
  String get pickLocationOnMap =>
      _es ? 'Elige una ubicación en el mapa' : 'Pick a location on the map';

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
  String get securedByStripe => _es
      ? 'Asegurado por Stripe. No almacenamos tus datos.'
      : "Secured by Stripe. We don't store your details.";
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
  String get bookScheduledRide =>
      _es ? 'Reservar viaje programado' : 'Book Scheduled Ride';
  String get enterBothAddresses => _es
      ? 'Ingresa el punto de recogida y destino'
      : 'Enter both pickup and destination';
  String get rideScheduled => _es ? 'Viaje programado' : 'Ride scheduled';
  String get readyLabel => _es ? 'Listo' : 'Ready';
  String get bestLabel => 'BEST';

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

  // ── Pickup/Dropoff Search (extra) ──────────────────────────────────────────
  String get typeToSearchAddress => _es
      ? 'Escribe para buscar una dirección'
      : 'Type to search for an address';
  String setAddressFor(String place) =>
      _es ? 'Establecer dirección de $place' : 'Set $place address';
  String searchAddressFor(String place) =>
      _es ? 'Busca tu dirección de $place' : 'Search your $place address';

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
  String chooseRide(String name) => _es ? 'Elegir $name' : 'Choose $name';
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
  String bookScheduledRidePrice(String price) => _es
      ? 'Reservar viaje programado · $price'
      : 'Book Scheduled Ride · $price';
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
  String get cancelFeeWarning => _es
      ? '¿Estás seguro? Puede aplicar una tarifa de cancelación.'
      : 'Are you sure? A cancellation fee may apply.';
  String get tripCancelledByOperator => _es
      ? 'Tu viaje ha sido cancelado por el operador. Por favor solicita un nuevo viaje.'
      : 'Your trip has been cancelled by the operator. Please request a new ride.';
  String get okButton => _es ? 'OK' : 'OK';
  String arrivalTime(String time) => _es ? 'Llegada $time' : 'Arrival $time';
  String etaLabel(String eta) => 'ETA $eta';
  String get driverEnRoute => _es ? 'Conductor en camino' : 'Driver en route';
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
      ? 'Al descargar, acceder o usar la aplicación Cruise ("App"), usted acepta estar sujeto a estos Términos y Condiciones ("Términos"). Si no está de acuerdo con estos Términos, por favor no use la App. Estos Términos constituyen un acuerdo legalmente vinculante entre usted y Cruise Technologies, Inc. ("Cruise", "nosotros" o "nuestro").'
      : 'By downloading, accessing, or using the Cruise application ("App"), you agree to be bound by these Terms and Conditions ("Terms"). If you do not agree to these Terms, please do not use the App. These Terms constitute a legally binding agreement between you and Cruise Technologies, Inc. ("Cruise," "we," or "our").';
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
      ? 'Al solicitar un viaje a través de la App:\n\n• Se le proporcionará una tarifa estimada antes de confirmar\n• Los precios pueden variar según la demanda, distancia y condiciones del tráfico\n• Se puede aplicar una tarifa de cancelación si cancela después de que un conductor ha sido asignado\n• Ventana de cancelación gratuita: 2 minutos después de la asignación del conductor\n• Tarifa de cancelación: \$5.00 (después de la ventana de cancelación gratuita)\n• La tarifa de no presentarse: \$10.00 si el conductor espera más de 5 minutos'
      : 'When you request a ride through the App:\n\n• You will be provided with an estimated fare before confirming\n• Prices may vary based on demand, distance, and traffic conditions\n• A cancellation fee may apply if you cancel after a driver has been assigned\n• Free cancellation window: 2 minutes after driver assignment\n• Cancellation fee: \$5.00 (after free cancellation window)\n• No-show fee: \$10.00 if driver waits more than 5 minutes';
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
      ? 'El nombre, logotipo, diseño de la app y todo el contenido relacionado de Cruise son propiedad de Cruise Technologies, Inc. y están protegidos por leyes de propiedad intelectual. No puede copiar, modificar, distribuir ni crear trabajos derivados sin nuestro consentimiento previo por escrito.'
      : 'The Cruise name, logo, app design, and all related content are the property of Cruise Technologies, Inc. and are protected by intellectual property laws. You may not copy, modify, distribute, or create derivative works without our prior written consent.';
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
      ? 'Cualquier disputa que surja de estos Términos o que se relacione con ellos será resuelta mediante arbitraje vinculante de acuerdo con las reglas de la Asociación Americana de Arbitraje (AAA). Ambas partes renuncian al derecho a un juicio con jurado o participar en una demanda colectiva.'
      : 'Any disputes arising from or relating to these Terms will be resolved through binding arbitration in accordance with the rules of the American Arbitration Association (AAA). Both parties waive the right to a jury trial or to participate in a class action lawsuit.';
  String get termsModificationsTitle =>
      _es ? '16. Modificaciones' : '16. Modifications';
  String get termsModificationsBody => _es
      ? 'Cruise se reserva el derecho de modificar estos Términos en cualquier momento. Los cambios entrarán en vigencia al ser publicados en la App. El uso continuado después de los cambios constituye la aceptación de los Términos modificados. Las modificaciones materiales serán notificadas por correo electrónico o notificación en la app.'
      : 'Cruise reserves the right to modify these Terms at any time. Changes will be effective upon posting to the App. Continued use after changes constitutes acceptance of the modified Terms. Material changes will be notified via email or in-app notification.';
  String get termsGoverningLawTitle =>
      _es ? '17. Ley Aplicable' : '17. Governing Law';
  String get termsGoverningLawBody => _es
      ? 'Estos Términos se regirán y serán interpretados de acuerdo con las leyes del Estado de Alabama, sin tener en cuenta los principios de conflictos de leyes. Cualquier acción legal no cubierta por arbitraje será presentada ante los tribunales estatales o federales ubicados en el Condado de Jefferson, Alabama.'
      : 'These Terms shall be governed by and construed in accordance with the laws of the State of Alabama, without regard to conflict of law principles. Any legal action not covered by arbitration shall be brought in the state or federal courts located in Jefferson County, Alabama.';
  String get termsContactTitle => _es ? '18. Contáctenos' : '18. Contact Us';
  String get termsContactBody => _es
      ? 'Si tiene alguna pregunta sobre estos Términos, contáctenos:\n\nCruise Technologies, Inc.\nEmail: legal@cruiseapp.com\nSoporte: support@cruiseapp.com'
      : 'If you have any questions about these Terms, please contact us:\n\nCruise Technologies, Inc.\nEmail: legal@cruiseapp.com\nSupport: support@cruiseapp.com';
  String get termsAcceptanceNotice => _es
      ? 'Al crear una cuenta o usar la app Cruise, usted reconoce que ha leído, comprendido y acepta estar sujeto a estos Términos y Condiciones.'
      : 'By creating an account or using the Cruise app, you acknowledge that you have read, understood, and agree to be bound by these Terms and Conditions.';

  // ── Driver Home ──
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
      ? 'Verde → Oro → Platino → Diamante'
      : 'Green → Gold → Platinum → Diamond';

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
  String get orDivider => _es ? 'o' : 'or';
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
      _es ? 'Solicitud Rechazada' : 'Application Rejected';
  String get rejectionDescription => _es
      ? 'Tu solicitud fue rechazada. Por favor revisa los detalles y vuelve a intentarlo.'
      : 'Your application was rejected. Please review the details and try again.';
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
      ? 'Vincula tu banco o tarjeta de débito con Plaid para pagos instantáneos. Retira cuando quieras.'
      : 'Link your bank or debit card via Plaid for instant payouts. Cash out anytime.';
  String get connectingLabel => _es ? 'Conectando...' : 'Connecting...';
  String get connectBankForCashouts => _es
      ? 'Conecta tu cuenta bancaria con Plaid\npara retiros instantáneos'
      : 'Connect your bank account with Plaid\nfor instant cashouts';
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
