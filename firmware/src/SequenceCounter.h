#pragma once
#include <stdint.h>

// Keep duplicate rejection across resets while avoiding an EEPROM write for
// every packet. Persist the next value every 16 commands. On each boot, skip
// another 16 values and immediately persist that new starting point.
class SequenceCounter {
public:
    static const uint8_t interval = 16;

    uint8_t begin(uint8_t saved) {
        next_ = static_cast<uint8_t>(saved + interval);
        unsaved_ = 0;
        return next_;
    }

    uint8_t next() {
        uint8_t value = next_++;
        ++unsaved_;
        return value;
    }

    bool needsCheckpoint() const { return unsaved_ >= interval; }

    uint8_t checkpoint() {
        unsaved_ = 0;
        return next_;
    }

private:
    uint8_t next_ = 0;
    uint8_t unsaved_ = 0;
};
