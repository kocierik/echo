#pragma once

#include <string>

class BondPolicy {
public:
    bool restore(const std::string& identity) {
        return accept(identity);
    }

    bool accept(const std::string& identity) {
        if (identity.empty()) return false;
        if (_acceptedIdentity.empty()) {
            _acceptedIdentity = identity;
            return true;
        }
        return _acceptedIdentity == identity;
    }

    bool hasPeer() const {
        return !_acceptedIdentity.empty();
    }

    const std::string& acceptedIdentity() const {
        return _acceptedIdentity;
    }

    void forget() {
        _acceptedIdentity.clear();
    }

private:
    std::string _acceptedIdentity;
};