# 🎨 Smooth UI/UX Guide - Cruise App

Guía completa para usar las transiciones ultra-fluidas y widgets optimizados.

## 🚀 Características Implementadas

### Transiciones de Página

Todas las transiciones usan curvas optimizadas para 60 FPS consistentes:

```dart
// 1. Fade + Slide (recomendada para la mayoría de pantallas)
Navigator.of(context).push(
  SmoothTransitions.fadeSlide(
    page: RideRequestScreen(),
    fromRight: true, // o false para izquierda
  ),
);

// 2. Scale + Fade (para modales/dialogs)
Navigator.of(context).push(
  SmoothTransitions.scaleFade(
    PaymentMethodsScreen(),
  ),
);

// 3. Slide Up (para bottom sheets/full screen)
Navigator.of(context).push(
  SmoothTransitions.slideUp(
    DriverProfileScreen(),
  ),
);

// 4. Shared Axis (para flujos relacionados)
Navigator.of(context).push(
  SmoothTransitions.sharedAxis(
    page: TripDetailsScreen(),
    axis: Axis.horizontal,
  ),
);

// 5. Circular Reveal (para FAB a pantalla)
Navigator.of(context).push(
  SmoothTransitions.circularReveal(
    page: NavigationScreen(),
    center: Offset(fabX, fabY),
  ),
);
```

### Widgets Suaves

#### Botones con Feedback Táctil

```dart
// Botón básico suave
SmoothButton(
  onTap: () => navigateToNextScreen(),
  child: Text('Request Ride'),
)

// Con personalización completa
SmoothButton(
  onTap: () => confirmBooking(),
  onLongPress: () => showOptions(),
  backgroundColor: Color(0xFF5BA3F5),
  foregroundColor: Colors.white,
  padding: EdgeInsets.symmetric(horizontal: 32, vertical: 18),
  borderRadius: BorderRadius.circular(16),
  elevation: 4,
  pressedElevation: 0,
  scaleOnPress: 0.96,
  enableHaptic: true,
  child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.local_taxi),
      SizedBox(width: 8),
      Text('Request Now'),
    ],
  ),
)
```

#### Cards con Hover

```dart
// Card que responde al hover/tap
SmoothCard(
  onTap: () => openRideDetails(),
  elevation: 2,
  hoverElevation: 12,
  pressedScale: 0.98,
  borderRadius: BorderRadius.circular(20),
  child: Padding(
    padding: EdgeInsets.all(16),
    child: RideInfoWidget(),
  ),
)
```

#### Loading Shimmer

```dart
// Skeleton loading suave
SmoothShimmer(
  child: Container(
    height: 100,
    decoration: BoxDecoration(
      color: Colors.grey[300],
      borderRadius: BorderRadius.circular(12),
    ),
  ),
)

// Lista con shimmer
SmoothShimmer(
  baseColor: Colors.grey[300],
  highlightColor: Colors.grey[100],
  duration: Duration(milliseconds: 1500),
  child: ListView.builder(
    itemCount: 5,
    itemBuilder: (_, i) => SkeletonCard(),
  ),
)
```

#### Listas con Stagger

```dart
// Lista con animación escalonada
SmoothListView(
  children: rideHistoryItems,
  padding: EdgeInsets.all(16),
)

// Fade in individual
SmoothFadeIn(
  delay: Duration(milliseconds: 100),
  duration: Duration(milliseconds: 500),
  child: MyWidget(),
)
```

#### Bottom Sheet Suave

```dart
// Bottom sheet con entrada suave
showModalBottomSheet(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  builder: (_) => SmoothBottomSheet(
    initialChildSize: 0.6,
    minChildSize: 0.3,
    maxChildSize: 0.9,
    child: RideOptionsContent(),
  ),
);
```

### Micro-Animaciones

```dart
// Fade in automático
SmoothTransitions.fadeIn(
  delay: Duration(milliseconds: 200),
  duration: Duration(milliseconds: 400),
  child: MyWidget(),
)

// Scale in con bounce
SmoothTransitions.scaleIn(
  delay: Duration(milliseconds: 100),
  child: SuccessIcon(),
)

// Slide in desde abajo
SmoothTransitions.slideInUp(
  delay: Duration.zero,
  child: BottomPanel(),
)

// Lista escalonada
SmoothTransitions.staggeredList(
  children: listItems,
  itemDelay: Duration(milliseconds: 50),
)
```

## 🎯 Ejemplos por Pantalla

### Home Screen (Rider)

```dart
class HomeScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SmoothListView(
        children: [
          // Header con fade in
          SmoothFadeIn(
            delay: Duration(milliseconds: 0),
            child: UserHeader(),
          ),
          
          // Botón principal suave
          SmoothFadeIn(
            delay: Duration(milliseconds: 100),
            child: SmoothButton(
              onTap: () => Navigator.push(
                context,
                SmoothTransitions.fadeSlide(
                  page: RideRequestScreen(),
                ),
              ),
              child: Text('Where to?'),
            ),
          ),
          
          // Cards de viajes recientes con stagger
          SmoothTransitions.staggeredList(
            children: recentRides.map((ride) => 
              SmoothCard(
                onTap: () => showRideDetails(ride),
                child: RideCard(ride: ride),
              ),
            ).toList(),
          ),
        ],
      ),
    );
  }
}
```

### Ride Request Screen

```dart
class RideRequestScreen extends StatefulWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Mapa
          MapWidget(),
          
          // Bottom sheet suave
          DraggableScrollableSheet(
            initialChildSize: 0.4,
            builder: (_, controller) {
              return SmoothBottomSheet(
                child: SmoothListView(
                  controller: controller,
                  children: [
                    // Opciones de ride
                    SmoothCard(
                      onTap: () => selectRideType('fusion'),
                      child: RideTypeOption(
                        type: 'Fusion',
                        price: '\$12.50',
                      ),
                    ),
                    
                    SmoothCard(
                      onTap: () => selectRideType('exec'),
                      child: RideTypeOption(
                        type: 'Executive',
                        price: '\$24.00',
                      ),
                    ),
                    
                    // Botón de confirmar
                    SmoothButton(
                      onTap: () => confirmRide(),
                      backgroundColor: Color(0xFF5BA3F5),
                      child: Text('Confirm Fusion'),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
```

### Driver Offers Screen

```dart
class DriverOffersScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ValueListenableBuilder<List<RideOffer>>(
        valueListenable: offersController.offersNotifier,
        builder: (_, offers, __) {
          if (offers.isEmpty) {
            // Shimmer loading
            return SmoothShimmer(
              child: ListView.builder(
                itemCount: 3,
                itemBuilder: (_, __) => SkeletonOfferCard(),
              ),
            );
          }
          
          return SmoothListView(
            children: offers.asMap().entries.map((entry) {
              return SmoothFadeIn(
                delay: Duration(milliseconds: entry.key * 80),
                child: SmoothCard(
                  onTap: () => viewOfferDetails(entry.value),
                  child: OfferCard(offer: entry.value),
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }
}
```

## ⚙️ Optimizaciones Implementadas

### 1. HTTP/Keep-Alive
```dart
// ApiService ahora usa:
// - Accept-Encoding: gzip, deflate
// - Connection: keep-alive
// - Persistent TCP connections
```

### 2. Scroll Suave Global
```dart
// Ya aplicado en main.dart via:
// - BouncingScrollPhysics en todas las plataformas
// - ScrollConfiguration global
```

### 3. Animaciones 60 FPS
```dart
// Curvas optimizadas:
// - easeOutExpo: Cubic(0.16, 1, 0.3, 1)
// - spring: Cubic(0.175, 0.885, 0.32, 1.275)
// - easeOutBack: Cubic(0.34, 1.56, 0.64, 1)
```

### 4. Haptic Feedback
```dart
// Todos los botones usan:
HapticFeedback.lightImpact(); // En tap
HapticFeedback.mediumImpact(); // En confirmaciones
```

## 📊 Performance Tips

### Evitar Jank

```dart
// ✅ BUENO: Usar const widgets
const SizedBox(height: 16)
const Text('Title', style: const TextStyle(...))

// ✅ BUENO: RepaintBoundary para elementos complejos
RepaintBoundary(
  child: ExpensiveWidget(),
)

// ✅ BUENO: Lazy loading para listas largas
ListView.builder(
  itemBuilder: (_, index) => items[index],
)

// ❌ MALO: Rebuilds innecesarios
setState(() => value = newValue) // en cada frame
```

### Memoria

```dart
// ✅ BUENO: Dispose controllers
@override
void dispose() {
  _controller.dispose();
  super.dispose();
}

// ✅ BUENO: Cachear imágenes
CachedNetworkImage(imageUrl: url)

// ✅ BUENO: Limitar tamaño de imágenes
Image.asset('photo.jpg', width: 200)
```

## 🧪 Testing

### Verificar 60 FPS

```bash
# En modo profile para verificar performance
flutter run --profile

# Verificar frames
cd android && ./gradlew assembleProfile
```

### Verificar Smoothness

```dart
// En debug, habilitar visualización de frames
class SmoothApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // Muestra barras de rendimiento
      showPerformanceOverlay: true,
      // ...
    );
  }
}
```

## 🎨 Customización

### Crear tu propia transición

```dart
class CustomTransition {
  static PageRouteBuilder<T> custom<T>(Widget page) {
    return PageRouteBuilder<T>(
      transitionDuration: Duration(milliseconds: 400),
      pageBuilder: (_, __, ___) => page,
      transitionsBuilder: (_, animation, __, child) {
        // Tu animación personalizada
        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            return Transform.rotate(
              angle: animation.value * 0.1,
              child: Opacity(
                opacity: animation.value,
                child: child,
              ),
            );
          },
          child: child,
        );
      },
    );
  }
}
```

### Curvas Personalizadas

```dart
// Definir curvas para 60 FPS consistentes
const Curve myCurve = Cubic(0.4, 0.0, 0.2, 1);

// Usar en animaciones
AnimationController(
  duration: Duration(milliseconds: 300),
  vsync: this,
);

final animation = CurvedAnimation(
  parent: controller,
  curve: myCurve,
);
```

## 📱 Compatibilidad

- **iOS**: Bouncing scroll nativo, haptics suaves
- **Android**: Scroll physics optimizado, ripple effects
- **Web**: Transiciones CSS-like, 60 FPS target

---

**Resultado**: App ultra-fluida con 60 FPS consistentes en todas las plataformas! 🚀
