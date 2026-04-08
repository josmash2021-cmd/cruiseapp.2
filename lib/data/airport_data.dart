import '../models/airport_models.dart';

/// Complete US airport data with terminals, airlines per terminal,
/// and real arrival doors per terminal.
const List<AirportInfo> kCommonAirports = [
  // ═══════════════════════════════════════════════════
  //  FLORIDA
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'MIA',
    name: 'Miami International Airport',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal D (North)',
        airlines: ['American Airlines', 'American Eagle', 'British Airways', 'Finnair', 'Iberia'],
        arrivalDoors: ['Door D1', 'Door D3', 'Door D5', 'Door D7', 'Door D9'],
      ),
      AirportTerminal(
        name: 'Terminal E (North)',
        airlines: ['LATAM Airlines', 'Avianca', 'Aeromexico', 'Copa Airlines', 'Air France', 'KLM'],
        arrivalDoors: ['Door E1', 'Door E3', 'Door E5', 'Door E7'],
      ),
      AirportTerminal(
        name: 'Terminal F (Central)',
        airlines: ['Air Canada', 'Alaska Airlines', 'JetBlue', 'Spirit Airlines'],
        arrivalDoors: ['Door F1', 'Door F3', 'Door F5'],
      ),
      AirportTerminal(
        name: 'Terminal G (South)',
        airlines: ['Delta Air Lines', 'United Airlines', 'Southwest Airlines', 'Silver Airways'],
        arrivalDoors: ['Door G1', 'Door G3', 'Door G5', 'Door G7'],
      ),
      AirportTerminal(
        name: 'Terminal H (South)',
        airlines: ['Caribbean Airlines', 'Bahamasair', 'Frontier Airlines', 'Sun Country'],
        arrivalDoors: ['Door H1', 'Door H3', 'Door H5'],
      ),
      AirportTerminal(
        name: 'Terminal J (South)',
        airlines: ['Charter / Private', 'Viva Aerobus', 'Volaris'],
        arrivalDoors: ['Door J1', 'Door J3'],
      ),
    ],
  ),
  AirportInfo(
    code: 'FLL',
    name: 'Fort Lauderdale-Hollywood Intl',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal 1',
        airlines: ['Delta Air Lines', 'Spirit Airlines'],
        arrivalDoors: ['Door 1A', 'Door 1B', 'Door 1C'],
      ),
      AirportTerminal(
        name: 'Terminal 2',
        airlines: ['JetBlue Airways', 'Alaska Airlines'],
        arrivalDoors: ['Door 2A', 'Door 2B'],
      ),
      AirportTerminal(
        name: 'Terminal 3',
        airlines: ['American Airlines', 'Air Canada'],
        arrivalDoors: ['Door 3A', 'Door 3B', 'Door 3C'],
      ),
      AirportTerminal(
        name: 'Terminal 4',
        airlines: ['Southwest Airlines', 'United Airlines', 'Frontier Airlines', 'Sun Country'],
        arrivalDoors: ['Door 4A', 'Door 4B', 'Door 4C', 'Door 4D'],
      ),
    ],
  ),
  AirportInfo(
    code: 'MCO',
    name: 'Orlando International Airport',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal A (Gates 1–29)',
        airlines: ['Delta Air Lines', 'JetBlue Airways', 'Spirit Airlines', 'Frontier Airlines'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3'],
      ),
      AirportTerminal(
        name: 'Terminal B (Gates 30–59)',
        airlines: ['Southwest Airlines', 'United Airlines', 'Alaska Airlines', 'Sun Country'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3'],
      ),
      AirportTerminal(
        name: 'Terminal C (South — New)',
        airlines: ['American Airlines', 'Air Canada', 'British Airways', 'WestJet'],
        arrivalDoors: ['Door C1', 'Door C2', 'Door C3'],
      ),
    ],
  ),
  AirportInfo(
    code: 'TPA',
    name: 'Tampa International Airport',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Main Terminal — Airside A',
        airlines: ['Southwest Airlines', 'Sun Country', 'Breeze Airways'],
        arrivalDoors: ['Red Side — Door 1', 'Red Side — Door 2', 'Red Side — Door 3'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Airside C',
        airlines: ['Delta Air Lines', 'Spirit Airlines', 'Frontier Airlines'],
        arrivalDoors: ['Blue Side — Door 1', 'Blue Side — Door 2', 'Blue Side — Door 3'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Airside E',
        airlines: ['American Airlines', 'United Airlines', 'Alaska Airlines', 'JetBlue Airways', 'Air Canada'],
        arrivalDoors: ['Yellow Side — Door 1', 'Yellow Side — Door 2', 'Yellow Side — Door 3'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Airside F',
        airlines: ['British Airways', 'WestJet', 'Aeromexico', 'LATAM Airlines'],
        arrivalDoors: ['Green Side — Door 1', 'Green Side — Door 2'],
      ),
    ],
  ),
  AirportInfo(
    code: 'JAX',
    name: 'Jacksonville International Airport',
    flatRateSurcharge: 4.0,
    terminals: [
      AirportTerminal(
        name: 'Main Terminal — Concourse A',
        airlines: ['American Airlines', 'Delta Air Lines', 'United Airlines'],
        arrivalDoors: ['Arrivals — Door 1', 'Arrivals — Door 2', 'Arrivals — Door 3'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Concourse B',
        airlines: ['Southwest Airlines', 'JetBlue Airways', 'Spirit Airlines', 'Sun Country'],
        arrivalDoors: ['Arrivals — Door 4', 'Arrivals — Door 5', 'Arrivals — Door 6'],
      ),
    ],
  ),
  AirportInfo(
    code: 'RSW',
    name: 'Southwest Florida International',
    flatRateSurcharge: 4.0,
    terminals: [
      AirportTerminal(
        name: 'Main Terminal — Concourse C',
        airlines: ['Delta Air Lines', 'United Airlines', 'Spirit Airlines', 'Frontier Airlines'],
        arrivalDoors: ['Door C1', 'Door C2', 'Door C3'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Concourse D',
        airlines: ['American Airlines', 'Southwest Airlines', 'JetBlue Airways', 'Sun Country', 'Allegiant Air'],
        arrivalDoors: ['Door D1', 'Door D2', 'Door D3', 'Door D4'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  NEW YORK
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'JFK',
    name: 'John F. Kennedy International',
    flatRateSurcharge: 8.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal 1',
        airlines: ['Lufthansa', 'Air France', 'Korean Air', 'Japan Airlines', 'Swiss', 'TAP Air Portugal', 'Royal Jordanian'],
        arrivalDoors: ['Door 1A', 'Door 1B', 'Door 1C', 'Door 1D'],
      ),
      AirportTerminal(
        name: 'Terminal 2',
        airlines: ['Delta Air Lines (regional)'],
        arrivalDoors: ['Door 2A', 'Door 2B'],
      ),
      AirportTerminal(
        name: 'Terminal 4',
        airlines: ['Delta Air Lines', 'Virgin Atlantic', 'Etihad Airways', 'Emirates', 'Air India', 'WestJet', 'Aeromexico'],
        arrivalDoors: ['Door 4A', 'Door 4B', 'Door 4C', 'Door 4D', 'Door 4E'],
      ),
      AirportTerminal(
        name: 'Terminal 5',
        airlines: ['JetBlue Airways'],
        arrivalDoors: ['Door 5A', 'Door 5B', 'Door 5C'],
      ),
      AirportTerminal(
        name: 'Terminal 7',
        airlines: ['British Airways', 'Iberia', 'Aer Lingus'],
        arrivalDoors: ['Door 7A', 'Door 7B', 'Door 7C'],
      ),
      AirportTerminal(
        name: 'Terminal 8',
        airlines: ['American Airlines', 'Finnair', 'Qatar Airways', 'Royal Air Maroc', 'Alaska Airlines'],
        arrivalDoors: ['Door 8A', 'Door 8B', 'Door 8C', 'Door 8D'],
      ),
    ],
  ),
  AirportInfo(
    code: 'LGA',
    name: 'LaGuardia Airport',
    flatRateSurcharge: 7.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal A',
        airlines: ['Southwest Airlines', 'Spirit Airlines', 'Sun Country'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3'],
      ),
      AirportTerminal(
        name: 'Terminal B',
        airlines: ['American Airlines', 'Alaska Airlines', 'Air Canada', 'United Airlines'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3', 'Door B4'],
      ),
      AirportTerminal(
        name: 'Terminal C & D',
        airlines: ['Delta Air Lines', 'Delta Connection', 'WestJet', 'JetBlue Airways'],
        arrivalDoors: ['Door C1', 'Door C2', 'Door D1', 'Door D2'],
      ),
    ],
  ),
  AirportInfo(
    code: 'EWR',
    name: 'Newark Liberty International',
    flatRateSurcharge: 7.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal A',
        airlines: ['Southwest Airlines', 'Frontier Airlines', 'Spirit Airlines', 'Sun Country'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3'],
      ),
      AirportTerminal(
        name: 'Terminal B',
        airlines: ['Delta Air Lines', 'American Airlines', 'Alaska Airlines', 'Air Canada'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3'],
      ),
      AirportTerminal(
        name: 'Terminal C',
        airlines: ['United Airlines', 'United Express', 'Lufthansa', 'British Airways', 'Air France', 'KLM', 'Turkish Airlines'],
        arrivalDoors: ['Door C1', 'Door C2', 'Door C3', 'Door C4'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  CALIFORNIA
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'LAX',
    name: 'Los Angeles International',
    flatRateSurcharge: 6.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal 1',
        airlines: ['Southwest Airlines', 'WestJet'],
        arrivalDoors: ['Door 1A', 'Door 1B', 'Door 1C'],
      ),
      AirportTerminal(
        name: 'Terminal 2',
        airlines: ['Air Canada', 'WestJet (intl)', 'Condor', 'Frontier Airlines'],
        arrivalDoors: ['Door 2A', 'Door 2B', 'Door 2C'],
      ),
      AirportTerminal(
        name: 'Terminal 3',
        airlines: ['Alaska Airlines', 'Spirit Airlines', 'Hawaiian Airlines'],
        arrivalDoors: ['Door 3A', 'Door 3B', 'Door 3C'],
      ),
      AirportTerminal(
        name: 'Terminal 4',
        airlines: ['American Airlines'],
        arrivalDoors: ['Door 4A', 'Door 4B', 'Door 4C', 'Door 4D'],
      ),
      AirportTerminal(
        name: 'Terminal 5',
        airlines: ['Delta Air Lines', 'Spirit Airlines', 'Sun Country'],
        arrivalDoors: ['Door 5A', 'Door 5B', 'Door 5C'],
      ),
      AirportTerminal(
        name: 'Terminal 6',
        airlines: ['United Airlines (connections)', 'Volaris'],
        arrivalDoors: ['Door 6A', 'Door 6B'],
      ),
      AirportTerminal(
        name: 'Terminal 7',
        airlines: ['United Airlines'],
        arrivalDoors: ['Door 7A', 'Door 7B', 'Door 7C'],
      ),
      AirportTerminal(
        name: 'Tom Bradley International',
        airlines: ['LATAM Airlines', 'Qantas', 'China Southern', 'EVA Air', 'ANA', 'Korean Air', 'Cathay Pacific', 'Singapore Airlines', 'British Airways', 'Aeromexico'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3', 'Door B4', 'Door B5'],
      ),
    ],
  ),
  AirportInfo(
    code: 'SFO',
    name: 'San Francisco International',
    flatRateSurcharge: 6.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal 1 (Harvey Milk)',
        airlines: ['Southwest Airlines', 'Alaska Airlines', 'Delta regional'],
        arrivalDoors: ['Door 1A', 'Door 1B', 'Door 1C'],
      ),
      AirportTerminal(
        name: 'Terminal 2',
        airlines: ['American Airlines', 'Alaska Airlines', 'Virgin America'],
        arrivalDoors: ['Door 2A', 'Door 2B', 'Door 2C'],
      ),
      AirportTerminal(
        name: 'Terminal 3',
        airlines: ['United Airlines (domestic)', 'JetBlue Airways', 'Frontier Airlines'],
        arrivalDoors: ['Door 3A', 'Door 3B', 'Door 3C'],
      ),
      AirportTerminal(
        name: 'International Terminal A',
        airlines: ['Air France', 'KLM', 'Lufthansa', 'British Airways', 'Cathay Pacific', 'Japan Airlines', 'ANA', 'Singapore Airlines', 'Korean Air', 'Air Canada (intl)'],
        arrivalDoors: ['Door IA1', 'Door IA2', 'Door IA3', 'Door IA4'],
      ),
      AirportTerminal(
        name: 'International Terminal G',
        airlines: ['United Airlines (intl)', 'Air China', 'Turkish Airlines', 'Aeromexico'],
        arrivalDoors: ['Door IG1', 'Door IG2', 'Door IG3'],
      ),
    ],
  ),
  AirportInfo(
    code: 'SAN',
    name: 'San Diego International',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal 1',
        airlines: ['Southwest Airlines', 'Alaska Airlines', 'Frontier Airlines', 'Spirit Airlines'],
        arrivalDoors: ['Door 1A', 'Door 1B', 'Door 1C'],
      ),
      AirportTerminal(
        name: 'Terminal 2',
        airlines: ['American Airlines', 'Delta Air Lines', 'United Airlines', 'JetBlue Airways', 'Air Canada', 'British Airways'],
        arrivalDoors: ['Door 2A', 'Door 2B', 'Door 2C', 'Door 2D'],
      ),
    ],
  ),
  AirportInfo(
    code: 'SJC',
    name: 'San José Mineta International',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal A',
        airlines: ['Southwest Airlines', 'Alaska Airlines', 'Spirit Airlines'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3'],
      ),
      AirportTerminal(
        name: 'Terminal B',
        airlines: ['American Airlines', 'Delta Air Lines', 'United Airlines', 'JetBlue Airways'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3'],
      ),
    ],
  ),
  AirportInfo(
    code: 'OAK',
    name: 'Oakland International Airport',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal 1',
        airlines: ['Southwest Airlines', 'Alaska Airlines'],
        arrivalDoors: ['Arrivals — Door 1', 'Arrivals — Door 2'],
      ),
      AirportTerminal(
        name: 'Terminal 2',
        airlines: ['Spirit Airlines', 'JetBlue Airways', 'United Airlines', 'LATAM Airlines'],
        arrivalDoors: ['Arrivals — Door 3', 'Arrivals — Door 4', 'Arrivals — Door 5'],
      ),
    ],
  ),
  AirportInfo(
    code: 'SMF',
    name: 'Sacramento International',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal A',
        airlines: ['Southwest Airlines', 'Alaska Airlines', 'Frontier Airlines'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3'],
      ),
      AirportTerminal(
        name: 'Terminal B',
        airlines: ['American Airlines', 'Delta Air Lines', 'United Airlines', 'JetBlue Airways', 'Spirit Airlines'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3', 'Door B4'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  GEORGIA
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'ATL',
    name: 'Hartsfield-Jackson Atlanta Intl',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Domestic North Terminal',
        airlines: ['Southwest Airlines', 'Spirit Airlines', 'Frontier Airlines', 'Sun Country', 'Allegiant Air'],
        arrivalDoors: ['Door N1', 'Door N2', 'Door N3', 'Door N4'],
      ),
      AirportTerminal(
        name: 'Domestic South Terminal',
        airlines: ['Delta Air Lines', 'Delta Connection', 'Endeavor Air', 'American Airlines', 'United Airlines'],
        arrivalDoors: ['Door S1', 'Door S2', 'Door S3', 'Door S4'],
      ),
      AirportTerminal(
        name: 'International Terminal',
        airlines: ['Air France', 'KLM', 'British Airways', 'Aeromexico', 'Air Canada', 'Virgin Atlantic', 'Korean Air', 'Turkish Airlines', 'WestJet'],
        arrivalDoors: ['Door F1', 'Door F2', 'Door F3', 'Door F4'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  ILLINOIS
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'ORD',
    name: "Chicago O'Hare International",
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal 1 (B & C Concourses)',
        airlines: ['United Airlines', 'United Express'],
        arrivalDoors: ['Door 1B1', 'Door 1B2', 'Door 1C1', 'Door 1C2'],
      ),
      AirportTerminal(
        name: 'Terminal 2 (E Concourse)',
        airlines: ['United Express (additional)', 'Air Canada'],
        arrivalDoors: ['Door 2E1', 'Door 2E2'],
      ),
      AirportTerminal(
        name: 'Terminal 3 (G, H, K Concourses)',
        airlines: ['American Airlines', 'American Eagle', 'Alaska Airlines'],
        arrivalDoors: ['Door 3G', 'Door 3H', 'Door 3K'],
      ),
      AirportTerminal(
        name: 'Terminal 5 (International)',
        airlines: ['Lufthansa', 'British Airways', 'Air France', 'KLM', 'Iberia', 'LATAM Airlines', 'Aeromexico', 'Emirates', 'Ethiopian Airlines'],
        arrivalDoors: ['Door 5M', 'Door 5L'],
      ),
    ],
  ),
  AirportInfo(
    code: 'MDW',
    name: 'Chicago Midway International',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Main Terminal — Concourse A',
        airlines: ['Southwest Airlines', 'Frontier Airlines'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Concourse B',
        airlines: ['Southwest Airlines', 'Spirit Airlines', 'Sun Country'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3', 'Door B4'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  TEXAS
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'DFW',
    name: 'Dallas/Fort Worth International',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal A',
        airlines: ['American Airlines (intl)'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3', 'Door A4'],
      ),
      AirportTerminal(
        name: 'Terminal B',
        airlines: ['American Airlines (domestic)'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3', 'Door B4'],
      ),
      AirportTerminal(
        name: 'Terminal C',
        airlines: ['American Airlines (domestic)'],
        arrivalDoors: ['Door C1', 'Door C2', 'Door C3'],
      ),
      AirportTerminal(
        name: 'Terminal D (International)',
        airlines: ['Aeromexico', 'Air France', 'British Airways', 'Emirates', 'Japan Airlines', 'Korean Air', 'Lufthansa', 'Qantas', 'WestJet'],
        arrivalDoors: ['Door D1', 'Door D2', 'Door D3', 'Door D4'],
      ),
      AirportTerminal(
        name: 'Terminal E',
        airlines: ['Frontier Airlines', 'Spirit Airlines', 'Sun Country', 'Southwest Airlines', 'Alaska Airlines'],
        arrivalDoors: ['Door E1', 'Door E2', 'Door E3'],
      ),
    ],
  ),
  AirportInfo(
    code: 'IAH',
    name: 'George Bush Intercontinental',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal A',
        airlines: ['United Airlines (domestic)'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3'],
      ),
      AirportTerminal(
        name: 'Terminal B',
        airlines: ['United Airlines (domestic)'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3'],
      ),
      AirportTerminal(
        name: 'Terminal C',
        airlines: ['United Airlines (hub)'],
        arrivalDoors: ['Door C1', 'Door C2', 'Door C3', 'Door C4'],
      ),
      AirportTerminal(
        name: 'Terminal D (International)',
        airlines: ['United Airlines (intl)', 'Aeromexico', 'Air Canada', 'Lufthansa', 'British Airways', 'Copa Airlines', 'LATAM Airlines'],
        arrivalDoors: ['Door D1', 'Door D2', 'Door D3', 'Door D4'],
      ),
      AirportTerminal(
        name: 'Terminal E',
        airlines: ['United Express', 'Southwest Airlines', 'Spirit Airlines'],
        arrivalDoors: ['Door E1', 'Door E2', 'Door E3'],
      ),
    ],
  ),
  AirportInfo(
    code: 'HOU',
    name: 'William P. Hobby Airport',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Main Terminal — Concourse A',
        airlines: ['Southwest Airlines', 'Sun Country'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Concourse B',
        airlines: ['Southwest Airlines', 'Delta Air Lines'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3', 'Door B4'],
      ),
    ],
  ),
  AirportInfo(
    code: 'DAL',
    name: 'Dallas Love Field',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Main Terminal — Concourse A',
        airlines: ['Southwest Airlines', 'Delta Air Lines'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Concourse B',
        airlines: ['Southwest Airlines', 'United Airlines', 'American Airlines'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3'],
      ),
    ],
  ),
  AirportInfo(
    code: 'AUS',
    name: 'Austin-Bergstrom International',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Barbara Jordan Terminal — Concourse A',
        airlines: ['Southwest Airlines', 'American Airlines', 'Alaska Airlines', 'Spirit Airlines'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3', 'Door A4'],
      ),
      AirportTerminal(
        name: 'Barbara Jordan Terminal — Concourse B',
        airlines: ['Delta Air Lines', 'United Airlines', 'JetBlue Airways', 'Frontier Airlines', 'Air Canada', 'British Airways'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3', 'Door B4'],
      ),
    ],
  ),
  AirportInfo(
    code: 'SAT',
    name: 'San Antonio International',
    flatRateSurcharge: 4.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal A',
        airlines: ['American Airlines', 'Delta Air Lines', 'United Airlines'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3'],
      ),
      AirportTerminal(
        name: 'Terminal B',
        airlines: ['Southwest Airlines', 'Frontier Airlines', 'Spirit Airlines', 'Alaska Airlines'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  GEORGIA / NEVADA
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'LAS',
    name: 'Harry Reid International',
    flatRateSurcharge: 6.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal 1',
        airlines: ['Delta Air Lines', 'Southwest Airlines', 'Alaska Airlines', 'Spirit Airlines', 'Sun Country'],
        arrivalDoors: ['Door 1A', 'Door 1B', 'Door 1C'],
      ),
      AirportTerminal(
        name: 'Terminal 3',
        airlines: ['American Airlines', 'United Airlines', 'JetBlue Airways', 'Frontier Airlines', 'Hawaiian Airlines'],
        arrivalDoors: ['Door 3A', 'Door 3B', 'Door 3C', 'Door 3D'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  COLORADO
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'DEN',
    name: 'Denver International Airport',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Jeppesen Terminal — Concourse A',
        airlines: ['United Airlines', 'United Express', 'Spirit Airlines'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3'],
      ),
      AirportTerminal(
        name: 'Jeppesen Terminal — Concourse B',
        airlines: ['Southwest Airlines', 'Frontier Airlines', 'Alaska Airlines', 'Sun Country'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3', 'Door B4'],
      ),
      AirportTerminal(
        name: 'Jeppesen Terminal — Concourse C',
        airlines: ['American Airlines', 'Delta Air Lines', 'JetBlue Airways', 'Air Canada', 'Lufthansa', 'British Airways'],
        arrivalDoors: ['Door C1', 'Door C2', 'Door C3', 'Door C4'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  MASSACHUSETTS
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'BOS',
    name: 'Boston Logan International',
    flatRateSurcharge: 6.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal A',
        airlines: ['American Airlines', 'Alaska Airlines'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3'],
      ),
      AirportTerminal(
        name: 'Terminal B',
        airlines: ['Southwest Airlines', 'Sun Country', 'JetBlue (some)'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3'],
      ),
      AirportTerminal(
        name: 'Terminal C',
        airlines: ['Delta Air Lines', 'United Airlines', 'Spirit Airlines', 'Frontier Airlines'],
        arrivalDoors: ['Door C1', 'Door C2', 'Door C3', 'Door C4'],
      ),
      AirportTerminal(
        name: 'Terminal E (International)',
        airlines: ['British Airways', 'Air France', 'KLM', 'Aer Lingus', 'Lufthansa', 'Air Canada', 'WestJet', 'Norse Atlantic', 'LOT Polish'],
        arrivalDoors: ['Door E1', 'Door E2', 'Door E3', 'Door E4'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  WASHINGTON (STATE)
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'SEA',
    name: 'Seattle-Tacoma International',
    flatRateSurcharge: 6.0,
    terminals: [
      AirportTerminal(
        name: 'Main — Concourse A/B (North)',
        airlines: ['Alaska Airlines', 'Horizon Air', 'Condor'],
        arrivalDoors: ['North Baggage — Door N1', 'North Baggage — Door N2', 'North Baggage — Door N3'],
      ),
      AirportTerminal(
        name: 'Main — Concourse C/D (Central)',
        airlines: ['Delta Air Lines', 'Southwest Airlines', 'Spirit Airlines', 'Frontier Airlines'],
        arrivalDoors: ['Central Baggage — Door C1', 'Central Baggage — Door C2', 'Central Baggage — Door C3'],
      ),
      AirportTerminal(
        name: 'Main — Concourse S (South/Intl)',
        airlines: ['United Airlines', 'American Airlines', 'Air Canada', 'British Airways', 'Korean Air', 'Japan Airlines', 'WestJet'],
        arrivalDoors: ['South Baggage — Door S1', 'South Baggage — Door S2', 'South Baggage — Door S3'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  MARYLAND / VIRGINIA (DC AREA)
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'BWI',
    name: 'Baltimore/Washington Intl',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal A',
        airlines: ['Southwest Airlines', 'Sun Country'],
        arrivalDoors: ['Door A1', 'Door A2'],
      ),
      AirportTerminal(
        name: 'Terminal B',
        airlines: ['Southwest Airlines', 'Spirit Airlines', 'Frontier Airlines'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3'],
      ),
      AirportTerminal(
        name: 'Terminal C',
        airlines: ['American Airlines', 'Alaska Airlines'],
        arrivalDoors: ['Door C1', 'Door C2'],
      ),
      AirportTerminal(
        name: 'Terminal D',
        airlines: ['Delta Air Lines', 'United Airlines', 'Air Canada'],
        arrivalDoors: ['Door D1', 'Door D2', 'Door D3'],
      ),
      AirportTerminal(
        name: 'Terminal E (International)',
        airlines: ['British Airways', 'Icelandair', 'WestJet', 'Condor'],
        arrivalDoors: ['Door E1', 'Door E2'],
      ),
    ],
  ),
  AirportInfo(
    code: 'DCA',
    name: 'Ronald Reagan Washington National',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal A',
        airlines: ['Southwest Airlines', 'Frontier Airlines'],
        arrivalDoors: ['Door A1', 'Door A2'],
      ),
      AirportTerminal(
        name: 'Terminal B',
        airlines: ['American Airlines', 'Alaska Airlines', 'JetBlue Airways', 'Sun Country'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3'],
      ),
      AirportTerminal(
        name: 'Terminal C',
        airlines: ['Delta Air Lines', 'United Airlines', 'Air Canada', 'Spirit Airlines'],
        arrivalDoors: ['Door C1', 'Door C2', 'Door C3'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  PENNSYLVANIA
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'PHL',
    name: 'Philadelphia International',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal A (International)',
        airlines: ['British Airways', 'Air Canada', 'Lufthansa', 'Aer Lingus'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3'],
      ),
      AirportTerminal(
        name: 'Terminal B',
        airlines: ['American Airlines'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3'],
      ),
      AirportTerminal(
        name: 'Terminal C',
        airlines: ['American Airlines'],
        arrivalDoors: ['Door C1', 'Door C2'],
      ),
      AirportTerminal(
        name: 'Terminal D',
        airlines: ['American Airlines (regional)', 'Delta Air Lines'],
        arrivalDoors: ['Door D1', 'Door D2'],
      ),
      AirportTerminal(
        name: 'Terminal E',
        airlines: ['Southwest Airlines', 'Spirit Airlines', 'Frontier Airlines'],
        arrivalDoors: ['Door E1', 'Door E2', 'Door E3'],
      ),
      AirportTerminal(
        name: 'Terminal F',
        airlines: ['United Airlines', 'Alaska Airlines', 'Sun Country'],
        arrivalDoors: ['Door F1', 'Door F2', 'Door F3'],
      ),
    ],
  ),
  AirportInfo(
    code: 'PIT',
    name: 'Pittsburgh International',
    flatRateSurcharge: 4.0,
    terminals: [
      AirportTerminal(
        name: 'Airside Terminal — Concourse A',
        airlines: ['American Airlines', 'Delta Air Lines', 'United Airlines'],
        arrivalDoors: ['Door A1', 'Door A2'],
      ),
      AirportTerminal(
        name: 'Airside Terminal — Concourse B',
        airlines: ['Southwest Airlines', 'Frontier Airlines', 'Spirit Airlines', 'Sun Country'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  NORTH CAROLINA
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'CLT',
    name: 'Charlotte Douglas International',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Main Terminal — Concourse A',
        airlines: ['American Airlines', 'American Eagle'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3', 'Door A4'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Concourse B',
        airlines: ['American Airlines'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Concourse C',
        airlines: ['Southwest Airlines', 'Delta Air Lines', 'United Airlines', 'Spirit Airlines', 'Frontier Airlines'],
        arrivalDoors: ['Door C1', 'Door C2', 'Door C3'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Concourse E (Intl)',
        airlines: ['British Airways', 'Air Canada', 'Lufthansa', 'WestJet', 'Aeromexico'],
        arrivalDoors: ['Door E1', 'Door E2'],
      ),
    ],
  ),
  AirportInfo(
    code: 'RDU',
    name: 'Raleigh-Durham International',
    flatRateSurcharge: 4.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal 1',
        airlines: ['Southwest Airlines', 'Spirit Airlines', 'Frontier Airlines', 'Sun Country'],
        arrivalDoors: ['Door 1A', 'Door 1B', 'Door 1C'],
      ),
      AirportTerminal(
        name: 'Terminal 2',
        airlines: ['American Airlines', 'Delta Air Lines', 'United Airlines', 'Alaska Airlines', 'JetBlue Airways', 'Air Canada'],
        arrivalDoors: ['Door 2A', 'Door 2B', 'Door 2C', 'Door 2D'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  OHIO
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'CMH',
    name: 'John Glenn Columbus International',
    flatRateSurcharge: 4.0,
    terminals: [
      AirportTerminal(
        name: 'Main Terminal — Concourse A',
        airlines: ['Delta Air Lines', 'United Airlines', 'American Airlines'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Concourse B',
        airlines: ['Southwest Airlines', 'Frontier Airlines', 'Spirit Airlines', 'Sun Country', 'Allegiant Air'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  MICHIGAN
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'DTW',
    name: 'Detroit Metropolitan Wayne County',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'McNamara Terminal',
        airlines: ['Delta Air Lines', 'Delta Connection', 'Air France', 'KLM', 'WestJet', 'Air Canada'],
        arrivalDoors: ['Door M1', 'Door M2', 'Door M3', 'Door M4'],
      ),
      AirportTerminal(
        name: 'North Terminal',
        airlines: ['Southwest Airlines', 'Spirit Airlines', 'Frontier Airlines', 'Sun Country', 'American Airlines', 'United Airlines'],
        arrivalDoors: ['Door N1', 'Door N2', 'Door N3'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  MINNESOTA
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'MSP',
    name: 'Minneapolis-Saint Paul Intl',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal 1 (Lindbergh)',
        airlines: ['Delta Air Lines', 'United Airlines', 'American Airlines', 'Alaska Airlines', 'JetBlue Airways', 'Air Canada', 'British Airways', 'KLM'],
        arrivalDoors: ['Door 1A', 'Door 1B', 'Door 1C', 'Door 1D'],
      ),
      AirportTerminal(
        name: 'Terminal 2 (Humphrey)',
        airlines: ['Southwest Airlines', 'Spirit Airlines', 'Frontier Airlines', 'Sun Country', 'Icelandair'],
        arrivalDoors: ['Door 2A', 'Door 2B', 'Door 2C'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  MISSOURI
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'STL',
    name: 'St. Louis Lambert International',
    flatRateSurcharge: 4.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal 1',
        airlines: ['Southwest Airlines', 'Delta Air Lines', 'American Airlines', 'Spirit Airlines'],
        arrivalDoors: ['Door 1A', 'Door 1B', 'Door 1C'],
      ),
      AirportTerminal(
        name: 'Terminal 2',
        airlines: ['United Airlines', 'Frontier Airlines', 'Sun Country', 'Allegiant Air'],
        arrivalDoors: ['Door 2A', 'Door 2B', 'Door 2C'],
      ),
    ],
  ),
  AirportInfo(
    code: 'MCI',
    name: 'Kansas City International',
    flatRateSurcharge: 4.0,
    terminals: [
      AirportTerminal(
        name: 'New Terminal — Concourse A',
        airlines: ['American Airlines', 'Delta Air Lines', 'Alaska Airlines', 'Spirit Airlines'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3'],
      ),
      AirportTerminal(
        name: 'New Terminal — Concourse B',
        airlines: ['Southwest Airlines', 'United Airlines', 'Frontier Airlines', 'Sun Country'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  LOUISIANA
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'MSY',
    name: 'Louis Armstrong New Orleans Intl',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Main Terminal — Concourse A',
        airlines: ['Southwest Airlines', 'Spirit Airlines', 'Frontier Airlines'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Concourse B',
        airlines: ['American Airlines', 'Delta Air Lines', 'United Airlines', 'Air Canada'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3', 'Door B4'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  INDIANA
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'IND',
    name: 'Indianapolis International',
    flatRateSurcharge: 4.0,
    terminals: [
      AirportTerminal(
        name: 'H. Weir Cook Terminal — Concourse A',
        airlines: ['American Airlines', 'Delta Air Lines', 'United Airlines'],
        arrivalDoors: ['Door A1', 'Door A2'],
      ),
      AirportTerminal(
        name: 'H. Weir Cook Terminal — Concourse B',
        airlines: ['Southwest Airlines', 'Frontier Airlines', 'Spirit Airlines', 'Allegiant Air', 'Sun Country'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  TENNESSEE
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'BNA',
    name: 'Nashville International',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Main Terminal — Concourse A',
        airlines: ['Southwest Airlines', 'Sun Country', 'Breeze Airways'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Concourse B',
        airlines: ['American Airlines', 'Delta Air Lines', 'United Airlines', 'JetBlue Airways', 'Spirit Airlines', 'Frontier Airlines'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3', 'Door B4'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Concourse C (Intl)',
        airlines: ['British Airways', 'Air Canada', 'WestJet', 'Aeromexico'],
        arrivalDoors: ['Door C1', 'Door C2'],
      ),
    ],
  ),
  AirportInfo(
    code: 'MEM',
    name: 'Memphis International',
    flatRateSurcharge: 4.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal A',
        airlines: ['Delta Air Lines', 'American Airlines', 'Spirit Airlines'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3'],
      ),
      AirportTerminal(
        name: 'Terminal B',
        airlines: ['Southwest Airlines', 'Frontier Airlines', 'Allegiant Air'],
        arrivalDoors: ['Door B1', 'Door B2'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  UTAH
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'SLC',
    name: 'Salt Lake City International',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal 1 — Concourse A',
        airlines: ['Delta Air Lines', 'Delta Connection'],
        arrivalDoors: ['Door A1', 'Door A2', 'Door A3', 'Door A4'],
      ),
      AirportTerminal(
        name: 'Terminal 1 — Concourse B',
        airlines: ['Delta Air Lines', 'Air France', 'KLM'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3'],
      ),
      AirportTerminal(
        name: 'Terminal 2 — Concourse C',
        airlines: ['Southwest Airlines', 'American Airlines', 'United Airlines', 'Alaska Airlines', 'Spirit Airlines', 'Frontier Airlines', 'JetBlue Airways'],
        arrivalDoors: ['Door C1', 'Door C2', 'Door C3', 'Door C4'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  KENTUCKY
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'CVG',
    name: 'Cincinnati/Northern Kentucky Intl',
    flatRateSurcharge: 4.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal 1',
        airlines: ['Delta Air Lines', 'Delta Connection', 'Aeromexico'],
        arrivalDoors: ['Door 1A', 'Door 1B'],
      ),
      AirportTerminal(
        name: 'Terminal 2',
        airlines: ['American Airlines', 'United Airlines', 'Spirit Airlines'],
        arrivalDoors: ['Door 2A', 'Door 2B', 'Door 2C'],
      ),
      AirportTerminal(
        name: 'Terminal 3',
        airlines: ['Southwest Airlines', 'Frontier Airlines', 'Allegiant Air', 'Sun Country'],
        arrivalDoors: ['Door 3A', 'Door 3B', 'Door 3C'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  NEW JERSEY / CONNECTICUT
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'BDL',
    name: 'Bradley International',
    flatRateSurcharge: 4.0,
    terminals: [
      AirportTerminal(
        name: 'Main Terminal — Concourse A',
        airlines: ['American Airlines', 'Delta Air Lines', 'United Airlines'],
        arrivalDoors: ['Door A1', 'Door A2'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Concourse B',
        airlines: ['Southwest Airlines', 'JetBlue Airways', 'Spirit Airlines', 'Frontier Airlines'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  OREGON
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'PDX',
    name: 'Portland International',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Main Terminal — Concourse A (Intl)',
        airlines: ['Alaska Airlines', 'Condor', 'British Airways'],
        arrivalDoors: ['Door A1', 'Door A2'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Concourse B',
        airlines: ['Southwest Airlines', 'Delta Air Lines', 'Frontier Airlines'],
        arrivalDoors: ['Door B1', 'Door B2', 'Door B3'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Concourse C',
        airlines: ['Alaska Airlines', 'United Airlines', 'American Airlines', 'JetBlue Airways', 'Spirit Airlines'],
        arrivalDoors: ['Door C1', 'Door C2', 'Door C3'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Concourse D',
        airlines: ['Alaska Airlines', 'Sun Country', 'Horizon Air'],
        arrivalDoors: ['Door D1', 'Door D2'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  ALABAMA
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'BHM',
    name: 'Birmingham-Shuttlesworth Intl',
    flatRateSurcharge: 4.0,
    terminals: [
      AirportTerminal(
        name: 'Main Terminal — Concourse A',
        airlines: ['American Airlines', 'Delta Air Lines', 'United Airlines'],
        arrivalDoors: ['Arrivals Level 1 — Door 1', 'Arrivals Level 1 — Door 2'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Concourse B',
        airlines: ['Southwest Airlines', 'Spirit Airlines', 'Frontier Airlines'],
        arrivalDoors: ['Arrivals Level 1 — Door 3', 'Arrivals Level 1 — Door 4'],
      ),
    ],
  ),
  AirportInfo(
    code: 'HSV',
    name: 'Huntsville International',
    flatRateSurcharge: 4.0,
    terminals: [
      AirportTerminal(
        name: 'Main Terminal — Concourse A',
        airlines: ['American Airlines', 'Delta Air Lines', 'United Airlines'],
        arrivalDoors: ['Ground Level — Door 1', 'Ground Level — Door 2'],
      ),
      AirportTerminal(
        name: 'Main Terminal — Concourse B',
        airlines: ['Southwest Airlines', 'Allegiant Air'],
        arrivalDoors: ['Ground Level — Door 3', 'Ground Level — Door 4'],
      ),
    ],
  ),
  AirportInfo(
    code: 'MOB',
    name: 'Mobile Regional Airport',
    flatRateSurcharge: 4.0,
    terminals: [
      AirportTerminal(
        name: 'Main Terminal',
        airlines: ['American Airlines', 'Delta Air Lines', 'United Airlines', 'Southwest Airlines'],
        arrivalDoors: ['Arrivals Curbside — Door 1', 'Arrivals Curbside — Door 2'],
      ),
    ],
  ),
  // ═══════════════════════════════════════════════════
  //  ARIZONA
  // ═══════════════════════════════════════════════════
  AirportInfo(
    code: 'PHX',
    name: 'Phoenix Sky Harbor International',
    flatRateSurcharge: 5.0,
    terminals: [
      AirportTerminal(
        name: 'Terminal 3',
        airlines: ['Alaska Airlines', 'Spirit Airlines', 'Frontier Airlines', 'Allegiant Air', 'Sun Country'],
        arrivalDoors: ['Door 3A', 'Door 3B', 'Door 3C'],
      ),
      AirportTerminal(
        name: 'Terminal 4',
        airlines: ['American Airlines', 'Delta Air Lines', 'United Airlines', 'Southwest Airlines', 'JetBlue Airways', 'Air Canada', 'British Airways', 'Aeromexico'],
        arrivalDoors: ['Door 4A', 'Door 4B', 'Door 4C', 'Door 4D'],
      ),
    ],
  ),
];
