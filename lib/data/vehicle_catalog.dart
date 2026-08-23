/// Curated vehicle catalogs for the driver onboarding "Add your vehicle"
/// capture screen. Keep small and stable — no network dependency.
library;

/// Model years allowed by platform policy (2012 or newer, up to next year).
List<int> vehicleYears() {
  final max = DateTime.now().year + 1;
  return [for (var y = max; y >= 2012; y--) y];
}

/// ~30 common US makes.
const List<String> vehicleMakes = [
  'Acura',
  'Audi',
  'BMW',
  'Buick',
  'Cadillac',
  'Chevrolet',
  'Chrysler',
  'Dodge',
  'Ford',
  'Genesis',
  'GMC',
  'Honda',
  'Hyundai',
  'Infiniti',
  'Jeep',
  'Kia',
  'Land Rover',
  'Lexus',
  'Lincoln',
  'Mazda',
  'Mercedes-Benz',
  'Mini',
  'Mitsubishi',
  'Nissan',
  'Ram',
  'Subaru',
  'Tesla',
  'Toyota',
  'Volkswagen',
  'Volvo',
];

/// Popular models per make — free text fallback when a make isn't listed
/// or the driver's model is missing.
const Map<String, List<String>> vehicleModels = {
  'Acura': ['ILX', 'Integra', 'MDX', 'RDX', 'TLX'],
  'Audi': ['A3', 'A4', 'A5', 'A6', 'Q3', 'Q5', 'Q7', 'Q8'],
  'BMW': ['2 Series', '3 Series', '4 Series', '5 Series', 'X1', 'X3', 'X5', 'X7'],
  'Buick': ['Encore', 'Encore GX', 'Enclave', 'Envision'],
  'Cadillac': ['CT4', 'CT5', 'Escalade', 'XT4', 'XT5', 'XT6'],
  'Chevrolet': [
    'Blazer', 'Bolt EV', 'Camaro', 'Colorado', 'Equinox', 'Impala',
    'Malibu', 'Silverado 1500', 'Suburban', 'Tahoe', 'Traverse', 'Trax',
  ],
  'Chrysler': ['300', 'Pacifica', 'Voyager'],
  'Dodge': ['Challenger', 'Charger', 'Durango', 'Grand Caravan', 'Journey'],
  'Ford': [
    'Bronco', 'Edge', 'Escape', 'Expedition', 'Explorer', 'F-150',
    'Fiesta', 'Focus', 'Fusion', 'Mustang', 'Ranger', 'Transit Connect',
  ],
  'Genesis': ['G70', 'G80', 'G90', 'GV70', 'GV80'],
  'GMC': ['Acadia', 'Canyon', 'Sierra 1500', 'Terrain', 'Yukon'],
  'Honda': [
    'Accord', 'Civic', 'CR-V', 'Fit', 'HR-V', 'Insight', 'Odyssey',
    'Passport', 'Pilot', 'Ridgeline',
  ],
  'Hyundai': [
    'Accent', 'Elantra', 'Ioniq', 'Kona', 'Palisade', 'Santa Fe',
    'Sonata', 'Tucson', 'Veloster', 'Venue',
  ],
  'Infiniti': ['Q50', 'Q60', 'QX50', 'QX60', 'QX80'],
  'Jeep': [
    'Cherokee', 'Compass', 'Gladiator', 'Grand Cherokee', 'Grand Wagoneer',
    'Renegade', 'Wagoneer', 'Wrangler',
  ],
  'Kia': [
    'Carnival', 'Forte', 'K5', 'Niro', 'Optima', 'Rio', 'Seltos',
    'Sorento', 'Soul', 'Sportage', 'Stinger', 'Telluride',
  ],
  'Land Rover': ['Defender', 'Discovery', 'Discovery Sport', 'Range Rover', 'Range Rover Evoque', 'Range Rover Sport'],
  'Lexus': ['ES', 'GX', 'IS', 'LS', 'LX', 'NX', 'RX', 'UX'],
  'Lincoln': ['Aviator', 'Continental', 'Corsair', 'MKZ', 'Nautilus', 'Navigator'],
  'Mazda': ['CX-3', 'CX-30', 'CX-5', 'CX-9', 'CX-90', 'Mazda3', 'Mazda6', 'MX-5 Miata'],
  'Mercedes-Benz': ['A-Class', 'C-Class', 'CLA', 'E-Class', 'GLA', 'GLB', 'GLC', 'GLE', 'GLS', 'S-Class'],
  'Mini': ['Clubman', 'Cooper', 'Countryman'],
  'Mitsubishi': ['Eclipse Cross', 'Mirage', 'Outlander', 'Outlander Sport'],
  'Nissan': [
    'Altima', 'Armada', 'Frontier', 'Kicks', 'Leaf', 'Maxima', 'Murano',
    'Pathfinder', 'Rogue', 'Sentra', 'Titan', 'Versa',
  ],
  'Ram': ['1500', '2500', 'ProMaster City'],
  'Subaru': ['Ascent', 'Crosstrek', 'Forester', 'Impreza', 'Legacy', 'Outback', 'WRX'],
  'Tesla': ['Model 3', 'Model S', 'Model X', 'Model Y'],
  'Toyota': [
    '4Runner', 'Avalon', 'Camry', 'C-HR', 'Corolla', 'Highlander',
    'Land Cruiser', 'Prius', 'RAV4', 'Sequoia', 'Sienna', 'Tacoma',
    'Tundra', 'Venza', 'Yaris',
  ],
  'Volkswagen': ['Atlas', 'Golf', 'GTI', 'ID.4', 'Jetta', 'Passat', 'Taos', 'Tiguan'],
  'Volvo': ['S60', 'S90', 'XC40', 'XC60', 'XC90'],
};

const List<String> vehicleColors = [
  'Black',
  'White',
  'Silver',
  'Gray',
  'Red',
  'Blue',
  'Green',
  'Brown',
  'Beige',
  'Gold',
  'Orange',
  'Yellow',
  'Purple',
  'Maroon',
];
