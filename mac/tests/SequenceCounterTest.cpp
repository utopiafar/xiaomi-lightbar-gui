#include "../../firmware/src/SequenceCounter.h"
#include <cassert>
#include <cstdint>
#include <iostream>

int main() {
    // Exercise every EEPROM value, partial checkpoint interval, and wraparound.
    for (int initial = 0; initial < 256; ++initial) {
        for (int count = 1; count <= 64; ++count) {
            uint8_t saved = static_cast<uint8_t>(initial);
            SequenceCounter first;
            saved = first.begin(saved);
            uint8_t previous = 0;
            for (int i = 0; i < count; ++i) {
                uint8_t value = first.next();
                if (i != 0) assert(value != previous);
                previous = value;
                if (first.needsCheckpoint()) saved = first.checkpoint();
            }
            SequenceCounter afterReset;
            saved = afterReset.begin(saved);
            assert(afterReset.next() != previous);
        }
    }
    std::cout << "sequence checkpoint and reset tests passed\n";
}
