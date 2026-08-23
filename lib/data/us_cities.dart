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

/// ~100 major US cities, grouped by state (alphabetical by state).
const List<UsStateGroup> kUsCitiesByState = [
  UsStateGroup('Alabama', 'AL', [
    UsCity('Pelham', 'AL'), UsCity('Birmingham', 'AL'),
    UsCity('Huntsville', 'AL'), UsCity('Montgomery', 'AL'),
    UsCity('Mobile', 'AL'), UsCity('Tuscaloosa', 'AL'),
  ]),
  UsStateGroup('Arizona', 'AZ', [
    UsCity('Phoenix', 'AZ'), UsCity('Tucson', 'AZ'),
    UsCity('Mesa', 'AZ'), UsCity('Scottsdale', 'AZ'),
  ]),
  UsStateGroup('Arkansas', 'AR', [
    UsCity('Little Rock', 'AR'), UsCity('Fayetteville', 'AR'),
  ]),
  UsStateGroup('California', 'CA', [
    UsCity('Los Angeles', 'CA'), UsCity('San Francisco', 'CA'),
    UsCity('San Diego', 'CA'), UsCity('Sacramento', 'CA'),
    UsCity('San Jose', 'CA'), UsCity('Fresno', 'CA'),
    UsCity('Oakland', 'CA'), UsCity('Long Beach', 'CA'),
    UsCity('Anaheim', 'CA'), UsCity('Riverside', 'CA'),
  ]),
  UsStateGroup('Colorado', 'CO', [
    UsCity('Denver', 'CO'), UsCity('Colorado Springs', 'CO'),
    UsCity('Aurora', 'CO'), UsCity('Boulder', 'CO'),
  ]),
  UsStateGroup('Connecticut', 'CT', [
    UsCity('Hartford', 'CT'), UsCity('New Haven', 'CT'),
    UsCity('Stamford', 'CT'),
  ]),
  UsStateGroup('Delaware', 'DE', [
    UsCity('Wilmington', 'DE'),
  ]),
  UsStateGroup('District of Columbia', 'DC', [
    UsCity('Washington', 'DC'),
  ]),
  UsStateGroup('Florida', 'FL', [
    UsCity('Miami', 'FL'), UsCity('Orlando', 'FL'),
    UsCity('Tampa', 'FL'), UsCity('Jacksonville', 'FL'),
    UsCity('Fort Lauderdale', 'FL'), UsCity('West Palm Beach', 'FL'),
    UsCity('Tallahassee', 'FL'), UsCity('Fort Myers', 'FL'),
  ]),
  UsStateGroup('Georgia', 'GA', [
    UsCity('Atlanta', 'GA'), UsCity('Savannah', 'GA'),
    UsCity('Augusta', 'GA'), UsCity('Athens', 'GA'),
  ]),
  UsStateGroup('Hawaii', 'HI', [
    UsCity('Honolulu', 'HI'),
  ]),
  UsStateGroup('Idaho', 'ID', [
    UsCity('Boise', 'ID'),
  ]),
  UsStateGroup('Illinois', 'IL', [
    UsCity('Chicago', 'IL'), UsCity('Springfield', 'IL'),
    UsCity('Naperville', 'IL'),
  ]),
  UsStateGroup('Indiana', 'IN', [
    UsCity('Indianapolis', 'IN'), UsCity('Fort Wayne', 'IN'),
  ]),
  UsStateGroup('Iowa', 'IA', [
    UsCity('Des Moines', 'IA'), UsCity('Cedar Rapids', 'IA'),
  ]),
  UsStateGroup('Kansas', 'KS', [
    UsCity('Wichita', 'KS'), UsCity('Kansas City', 'KS'),
  ]),
  UsStateGroup('Kentucky', 'KY', [
    UsCity('Louisville', 'KY'), UsCity('Lexington', 'KY'),
  ]),
  UsStateGroup('Louisiana', 'LA', [
    UsCity('New Orleans', 'LA'), UsCity('Baton Rouge', 'LA'),
  ]),
  UsStateGroup('Maryland', 'MD', [
    UsCity('Baltimore', 'MD'),
  ]),
  UsStateGroup('Massachusetts', 'MA', [
    UsCity('Boston', 'MA'), UsCity('Worcester', 'MA'),
  ]),
  UsStateGroup('Michigan', 'MI', [
    UsCity('Detroit', 'MI'), UsCity('Grand Rapids', 'MI'),
    UsCity('Ann Arbor', 'MI'),
  ]),
  UsStateGroup('Minnesota', 'MN', [
    UsCity('Minneapolis', 'MN'), UsCity('Saint Paul', 'MN'),
  ]),
  UsStateGroup('Mississippi', 'MS', [
    UsCity('Jackson', 'MS'),
  ]),
  UsStateGroup('Missouri', 'MO', [
    UsCity('Kansas City', 'MO'), UsCity('St. Louis', 'MO'),
    UsCity('Springfield', 'MO'),
  ]),
  UsStateGroup('Montana', 'MT', [
    UsCity('Billings', 'MT'),
  ]),
  UsStateGroup('Nebraska', 'NE', [
    UsCity('Omaha', 'NE'), UsCity('Lincoln', 'NE'),
  ]),
  UsStateGroup('Nevada', 'NV', [
    UsCity('Las Vegas', 'NV'), UsCity('Reno', 'NV'),
  ]),
  UsStateGroup('New Hampshire', 'NH', [
    UsCity('Manchester', 'NH'),
  ]),
  UsStateGroup('New Jersey', 'NJ', [
    UsCity('Newark', 'NJ'), UsCity('Jersey City', 'NJ'),
    UsCity('Atlantic City', 'NJ'),
  ]),
  UsStateGroup('New Mexico', 'NM', [
    UsCity('Albuquerque', 'NM'), UsCity('Santa Fe', 'NM'),
  ]),
  UsStateGroup('New York', 'NY', [
    UsCity('New York', 'NY'), UsCity('Buffalo', 'NY'),
    UsCity('Rochester', 'NY'), UsCity('Albany', 'NY'),
  ]),
  UsStateGroup('North Carolina', 'NC', [
    UsCity('Charlotte', 'NC'), UsCity('Raleigh', 'NC'),
    UsCity('Durham', 'NC'), UsCity('Greensboro', 'NC'),
    UsCity('Asheville', 'NC'),
  ]),
  UsStateGroup('Ohio', 'OH', [
    UsCity('Columbus', 'OH'), UsCity('Cleveland', 'OH'),
    UsCity('Cincinnati', 'OH'), UsCity('Toledo', 'OH'),
  ]),
  UsStateGroup('Oklahoma', 'OK', [
    UsCity('Oklahoma City', 'OK'), UsCity('Tulsa', 'OK'),
  ]),
  UsStateGroup('Oregon', 'OR', [
    UsCity('Portland', 'OR'), UsCity('Salem', 'OR'),
    UsCity('Eugene', 'OR'),
  ]),
  UsStateGroup('Pennsylvania', 'PA', [
    UsCity('Philadelphia', 'PA'), UsCity('Pittsburgh', 'PA'),
  ]),
  UsStateGroup('Rhode Island', 'RI', [
    UsCity('Providence', 'RI'),
  ]),
  UsStateGroup('South Carolina', 'SC', [
    UsCity('Charleston', 'SC'), UsCity('Columbia', 'SC'),
    UsCity('Greenville', 'SC'), UsCity('Myrtle Beach', 'SC'),
  ]),
  UsStateGroup('Tennessee', 'TN', [
    UsCity('Nashville', 'TN'), UsCity('Memphis', 'TN'),
    UsCity('Knoxville', 'TN'), UsCity('Chattanooga', 'TN'),
  ]),
  UsStateGroup('Texas', 'TX', [
    UsCity('Houston', 'TX'), UsCity('Dallas', 'TX'),
    UsCity('Austin', 'TX'), UsCity('San Antonio', 'TX'),
    UsCity('Fort Worth', 'TX'), UsCity('El Paso', 'TX'),
    UsCity('Plano', 'TX'), UsCity('Corpus Christi', 'TX'),
  ]),
  UsStateGroup('Utah', 'UT', [
    UsCity('Salt Lake City', 'UT'), UsCity('Provo', 'UT'),
  ]),
  UsStateGroup('Virginia', 'VA', [
    UsCity('Virginia Beach', 'VA'), UsCity('Richmond', 'VA'),
    UsCity('Norfolk', 'VA'), UsCity('Arlington', 'VA'),
  ]),
  UsStateGroup('Washington', 'WA', [
    UsCity('Seattle', 'WA'), UsCity('Spokane', 'WA'),
    UsCity('Tacoma', 'WA'),
  ]),
  UsStateGroup('Wisconsin', 'WI', [
    UsCity('Milwaukee', 'WI'), UsCity('Madison', 'WI'),
  ]),
];

/// ~100 major US cities, grouped by state (alphabetical by state).