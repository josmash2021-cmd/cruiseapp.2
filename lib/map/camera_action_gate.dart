class CameraActionGate {
  int _sequence = 0;

  int begin() => ++_sequence;

  bool isCurrent(int sequence) => sequence == _sequence;
}
