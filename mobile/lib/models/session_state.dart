enum SessionStatus { loggedIn, loggingOut, loggedOut, cleanupFailed }

final class SessionState {
  const SessionState(this.status, {this.error});

  final SessionStatus status;
  final String? error;

  bool get loggedIn => status == SessionStatus.loggedIn;
  bool get loggingOut => status == SessionStatus.loggingOut;
  bool get loggedOut => status == SessionStatus.loggedOut;
  bool get cleanupFailed => status == SessionStatus.cleanupFailed;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SessionState && status == other.status && error == other.error;
  }

  @override
  int get hashCode => Object.hash(status, error);
}