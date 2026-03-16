# Paneles de Acción para Drivers - Documentación

## Descripción General

Se han creado paneles visuales prominentes que aparecen durante la navegación del driver, mostrando botones de acción contextuales según la fase del viaje.

## Ubicación de Archivos

- **Widget Principal**: `lib/widgets/driver_action_panel.dart`
- **Integración**: `lib/pages/driver_navigation_page.dart`
- **Máquina de Estados**: `lib/navigation/nav_state_machine.dart`

## Fases del Viaje y Paneles

### 1. **Navegando al Pickup** (`TripPhase.toPickup`)
**Panel Verde**
- **Título**: "Dirigiéndose al punto de recogida"
- **Información**: Muestra ETA y distancia al pickup
- **Botón**: "LLEGUÉ AL PICKUP" (blanco sobre verde)
- **Acción**: Marca que el driver llegó al punto de recogida

### 2. **Llegado al Pickup** (`TripPhase.arrivedPickup`)
**Panel Dorado**
- **Título**: "Llegaste al punto de recogida"
- **Información**: "Esperando al pasajero"
- **Botón**: "INICIAR VIAJE" (blanco con ícono de play)
- **Acción**: Inicia el viaje cuando el pasajero sube al vehículo

### 3. **En Viaje al Destino** (`TripPhase.onTrip`)
**Panel Azul**
- **Título**: "En viaje al destino"
- **Información**: Muestra ETA y distancia al destino
- **Botón**: "LLEGUÉ AL DESTINO" (blanco sobre azul)
- **Acción**: Marca que el driver llegó al destino final

### 4. **Llegado al Destino** (`TripPhase.arrivedDropoff`)
**Panel Dorado**
- **Título**: "Llegaste al destino"
- **Información**: "Pasajero ha llegado a su destino"
- **Botón**: "FINALIZAR VIAJE" (blanco con ícono de bandera)
- **Acción**: Completa el viaje y actualiza el estado en el backend

## Características de los Paneles

### Diseño Visual
- **Gradientes**: Cada panel usa gradientes de color según la fase
- **Sombras**: Sombras pronunciadas para destacar sobre el mapa
- **Bordes Redondeados**: 20px de radio para un look moderno
- **Iconos**: Iconos contextuales que refuerzan el estado actual

### Interactividad
- **Haptic Feedback**: Vibración al presionar botones
- **Animaciones**: Transiciones suaves entre estados
- **Responsive**: Se adapta a diferentes tamaños de pantalla

### Información Contextual
- **ETA**: Tiempo estimado de llegada en minutos
- **Distancia**: Distancia restante en millas
- **Estado Visual**: Color del panel indica la fase actual

## Integración con el Backend

Los paneles están integrados con el servicio API:

```dart
// Al finalizar el viaje
await ApiService.updateTripStatus(
  tripId: tripId, 
  status: 'completed'
);
```

## Posicionamiento en la Pantalla

Los paneles aparecen en la parte superior de la pantalla de navegación:
- **Top**: `top + 180` (debajo del banner de navegación)
- **Ancho**: Ocupa todo el ancho con márgenes de 16px
- **Z-Index**: Por encima del mapa pero debajo de controles flotantes

## Flujo de Estados

```
toPickup → arrivedPickup → onTrip → arrivedDropoff → completed
   ↓            ↓            ↓            ↓
 Panel       Panel        Panel        Panel
 Verde       Dorado       Azul         Dorado
```

## Callbacks Implementados

- `onArrivedAtPickup()`: Transición a estado "arrivedPickup"
- `onStartTrip()`: Transición a estado "onTrip"
- `onArrivedAtDropoff()`: Transición a estado "arrivedDropoff"
- `onFinishTrip()`: Completa el viaje y cierra la navegación

## Personalización

Para modificar los colores o textos, edita las constantes en `driver_action_panel.dart`:

```dart
static const _green = Color(0xFF34A853);  // Verde para pickup
static const _gold = Color(0xFFD4A24C);   // Dorado para estados de espera
static const _red = Color(0xFFEF5350);    // Rojo (no usado actualmente)
```

## Notas de Implementación

1. Los paneles solo se muestran durante las fases activas del viaje
2. El panel se oculta automáticamente en estado `idle` o `completed`
3. La información de ETA y distancia se actualiza en tiempo real
4. Los botones tienen feedback háptico para mejor UX
