enum SessionStatus { loggedIn, loggingOut, loggedOut, cleanupFailed }

final class SessionState {
  const SessionState(this.status, {this.error, this.reason});

  final SessionStatus status;
  final String? error;

  /// Why the phone was signed out when it was not the user's choice
  /// ("This phone was signed out."), shown on the welcome.
  final String? reason;

  bool get loggedIn => status == SessionStatus.loggedIn;
  bool get loggingOut => status == SessionStatus.loggingOut;
  bool get loggedOut => status == SessionStatus.loggedOut;
  bool get cleanupFailed => status == SessionStatus.cleanupFailed;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SessionState &&
            status == other.status &&
            error == other.error &&
            reason == other.reason;
  }

  @override
  int get hashCode => Object.hash(status, error, reason);
}