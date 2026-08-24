/// Curated list of major US cities grouped by state, for the driver
/// onboarding "Where do you plan to drive?" picker.
library;

/// One selectable city: display name + USPS state code.
class UsCity {
  final String name;
  final String stateCode;
  const UsCity(this.name, this.stateCode);

  /// "Pelham, AL" — how the picked city renders in the field.
  String get label => '$name, $stateCode';
}

/// One state section in the picker.
class UsStateGroup {
  final String stateName;
  final String stateCode;
  final List<UsCity> cities;
  const UsStateGroup(this.stateName, this.stateCode, this.cities);
}

/// Full state name → USPS code (used to normalize reverse-geocode results,
/// which return the long name in `administrativeArea`).
const Map<String, String> kUsStateNameToCode = {
  'Alabama': 'AL', 'Alaska': 'AK', 'Arizona': 'AZ', 'Arkansas': 'AR',
  'California': 'CA', 'Colorado': 'CO', 'Connecticut': 'CT', 'Delaware': 'DE',
  'District of Columbia': 'DC', 'Florida': 'FL', 'Georgia': 'GA',
  'Hawaii': 'HI', 'Idaho': 'ID', 'Illinois': 'IL', 'Indiana': 'IN',
  'Iowa': 'IA', 'Kansas': 'KS', 'Kentucky': 'KY', 'Louisiana': 'LA',
  'Maine': 'ME', 'Maryland': 'MD', 'Massachusetts': 'MA', 'Michigan': 'MI',
  'Minnesota': 'MN', 'Mississippi': 'MS', 'Missouri': 'MO', 'Montana': 'MT',
  'Nebraska': 'NE', 'Nevada': 'NV', 'New Hampshire': 'NH', 'New Jersey': 'NJ',
  'New Mexico': 'NM', 'New York': 'NY', 'North Carolina': 'NC',
  'North Dakota': 'ND', 'Ohio': 'OH', 'Oklahoma': 'OK', 'Oregon': 'OR',
  'Pennsylvania': 'PA', 'Rhode Island': 'RI', 'South Carolina': 'SC',
  'South Dakota': 'SD', 'Tennessee': 'TN', 'Texas': 'TX', 'Utah': 'UT',
  'Vermont': 'VT', 'Virginia': 'VA', 'Washington': 'WA',
  'West Virginia': 'WV', 'Wisconsin': 'WI', 'Wyoming': 'WY',
};

/// Curated launch cities, grouped by state (alphabetical by state).
/// CruiseApp only operates in Alabama, Florida and Texas for now.
const List<UsStateGroup> kUsCitiesByState = [
  UsStateGroup('Alabama', 'AL', [
    UsCity('Pelham', 'AL'), UsCity('Birmingham', 'AL'),
    UsCity('Huntsville', 'AL'), UsCity('Montgomery', 'AL'),
    UsCity('Mobile', 'AL'), UsCity('Tuscaloosa', 'AL'),
  ]),
  UsStateGroup('Florida', 'FL', [
    UsCity('Miami', 'FL'), UsCity('Orlando', 'FL'),
    UsCity('Tampa', 'FL'), UsCity('Jacksonville', 'FL'),
    UsCity('Fort Lauderdale', 'FL'), UsCity('West Palm Beach', 'FL'),
    UsCity('Tallahassee', 'FL'), UsCity('Fort Myers', 'FL'),
    UsCity('St. Petersburg', 'FL'), UsCity('Gainesville', 'FL'),
  ]),
  UsStateGroup('Texas', 'TX', [
    UsCity('Houston', 'TX'), UsCity('Dallas', 'TX'),
    UsCity('Austin', 'TX'), UsCity('San Antonio', 'TX'),
    UsCity('Fort Worth', 'TX'), UsCity('El Paso', 'TX'),
    UsCity('Plano', 'TX'), UsCity('Corpus Christi', 'TX'),
    UsCity('Arlington', 'TX'), UsCity('Lubbock', 'TX'),
    UsCity('McAllen', 'TX'), UsCity('Frisco', 'TX'),
  ]),
];