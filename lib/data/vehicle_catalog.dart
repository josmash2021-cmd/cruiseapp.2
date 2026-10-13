/// Curated vehicle catalogs for the driver onboarding "Add your vehicle"
/// capture screen. Keep small and stable — no network dependency.
library;

/// Model years allowed by platform policy (2018 or newer, up to next year).
List<int> vehicleYears() {
  final max = DateTime.now().year + 1;
  return [for (var y = max; y >= 2018; y--) y];
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
  'Lucid',
  'Mazda',
  'Mercedes-Benz',
  'Mini',
  'Mitsubishi',
  'Nissan',
  'Polestar',
  'Porsche',
  'Ram',
  'Rivian',
  'Subaru',
  'Tesla',
  'Toyota',
  'Volkswagen',
  'Volvo',
];

/// Popular models per make — free text fallback when a make isn't listed
/// or the driver's model is missing. BEV models are included on purpose
/// (Electric Pro, 2026-10-13): the backend classifier already knows them.
const Map<String, List<String>> vehicleModels = {
  'Acura': ['ILX', 'Integra', 'MDX', 'RDX', 'TLX'],
  'Audi': ['A3', 'A4', 'A5', 'A6', 'e-tron', 'e-tron GT', 'Q3', 'Q4 e-tron', 'Q5', 'Q7', 'Q8'],
  'BMW': ['2 Series', '3 Series', '4 Series', '5 Series', 'i4', 'i7', 'iX', 'X1', 'X3', 'X5', 'X7'],
  'Buick': ['Encore', 'Encore GX', 'Enclave', 'Envision'],
  'Cadillac': ['CT4', 'CT5', 'Escalade', 'Lyriq', 'Optiq', 'XT4', 'XT5', 'XT6'],
  'Chevrolet': [
    'Blazer', 'Blazer EV', 'Bolt EUV', 'Bolt EV', 'Camaro', 'Colorado',
    'Equinox', 'Equinox EV', 'Impala', 'Malibu', 'Silverado 1500',
    'Silverado EV', 'Suburban', 'Tahoe', 'Traverse', 'Trax',
  ],
  'Chrysler': ['300', 'Pacifica', 'Voyager'],
  'Dodge': ['Challenger', 'Charger', 'Durango', 'Grand Caravan', 'Journey'],
  'Ford': [
    'Bronco', 'Edge', 'Escape', 'Expedition', 'Explorer', 'F-150',
    'F-150 Lightning', 'Fiesta', 'Focus', 'Fusion', 'Mustang',
    'Mustang Mach-E', 'Ranger', 'Transit Connect',
  ],
  'Genesis': ['G70', 'G80', 'G90', 'GV70', 'GV80'],
  'GMC': ['Acadia', 'Canyon', 'Sierra 1500', 'Terrain', 'Yukon'],
  'Honda': [
    'Accord', 'Civic', 'CR-V', 'Fit', 'HR-V', 'Insight', 'Odyssey',
    'Passport', 'Pilot', 'Prologue', 'Ridgeline',
  ],
  'Hyundai': [
    'Accent', 'Elantra', 'Ioniq', 'Ioniq 5', 'Ioniq 6', 'Kona', 'Palisade',
    'Santa Fe', 'Sonata', 'Tucson', 'Veloster', 'Venue',
  ],
  'Infiniti': ['Q50', 'Q60', 'QX50', 'QX60', 'QX80'],
  'Jeep': [
    'Cherokee', 'Compass', 'Gladiator', 'Grand Cherokee', 'Grand Wagoneer',
    'Renegade', 'Wagoneer', 'Wrangler',
  ],
  'Kia': [
    'Carnival', 'EV6', 'EV9', 'Forte', 'K5', 'Niro', 'Optima', 'Rio',
    'Seltos', 'Sorento', 'Soul', 'Sportage', 'Stinger', 'Telluride',
  ],
  'Land Rover': ['Defender', 'Discovery', 'Discovery Sport', 'Range Rover', 'Range Rover Evoque', 'Range Rover Sport'],
  'Lexus': ['ES', 'GX', 'IS', 'LS', 'LX', 'NX', 'RX', 'RZ', 'UX'],
  'Lincoln': ['Aviator', 'Continental', 'Corsair', 'MKZ', 'Nautilus', 'Navigator'],
  'Lucid': ['Air'],
  'Mazda': ['CX-3', 'CX-30', 'CX-5', 'CX-9', 'CX-90', 'Mazda3', 'Mazda6', 'MX-5 Miata'],
  'Mercedes-Benz': ['A-Class', 'C-Class', 'CLA', 'E-Class', 'EQB', 'EQE', 'EQE SUV', 'EQS', 'EQS SUV', 'GLA', 'GLB', 'GLC', 'GLE', 'GLS', 'S-Class'],
  'Mini': ['Clubman', 'Cooper', 'Countryman'],
  'Mitsubishi': ['Eclipse Cross', 'Mirage', 'Outlander', 'Outlander Sport'],
  'Nissan': [
    'Altima', 'Ariya', 'Armada', 'Frontier', 'Kicks', 'Leaf', 'Maxima',
    'Murano', 'Pathfinder', 'Rogue', 'Sentra', 'Titan', 'Versa',
  ],
  'Polestar': ['Polestar 2', 'Polestar 3'],
  'Porsche': ['Taycan'],
  'Ram': ['1500', '2500', 'ProMaster City'],
  'Rivian': ['R1S', 'R1T'],
  'Subaru': ['Ascent', 'Crosstrek', 'Forester', 'Impreza', 'Legacy', 'Outback', 'Solterra', 'WRX'],
  'Tesla': ['Cybertruck', 'Model 3', 'Model S', 'Model X', 'Model Y'],
  'Toyota': [
    '4Runner', 'Avalon', 'bZ4X', 'Camry', 'C-HR', 'Corolla', 'Highlander',
    'Land Cruiser', 'Prius', 'RAV4', 'Sequoia', 'Sienna', 'Tacoma',
    'Tundra', 'Venza', 'Yaris',
  ],
  'Volkswagen': ['Atlas', 'Golf', 'GTI', 'ID.4', 'ID. Buzz', 'Jetta', 'Passat', 'Taos', 'Tiguan'],
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

/// Seats / seatbelts a rideshare car can plausibly carry. Platform policy
/// floors at 5 belts; 4 stays selectable so the reviewer sees the real
/// number instead of a rounded-up lie.
const List<int> vehicleCapacityOptions = [4, 5, 6, 7, 8];
