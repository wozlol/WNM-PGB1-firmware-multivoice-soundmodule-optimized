#!/usr/bin/env python3
"""Generate pitch-zoned band-limited copies of the Chord engine's waveforms.

The Chord engine reads a single 256-point wavetable at every pitch, so at
high notes the table's upper harmonics land above Nyquist and fold back
down as inharmonic partials. That is heard as fizz plus slow beating that
gets worse the higher you play.

This emits, for each waveform, one copy per pitch zone with the harmonics
that would fold already removed. Picking the right copy by pitch costs one
array index at render time and no RAM, since the tables are constant and
live in flash. It is the same approach Tresses already uses for its own
Bandlimited_Comb_Table.

Zones where nothing needs removing point straight at the original Tresses
table, so the sound below the folding threshold stays bit-identical.

Run from the repo root:  python3 scripts/gen_chord_wavetables.py
"""

import cmath
import math
import os
import re
import sys

SAMPLE_RATE = 32000
TABLE_SIZE = 256          # points per period in the Tresses source tables
MAX_HARMONIC = TABLE_SIZE // 2   # the source table cannot hold more

# Points per period we emit. Linear interpolation error falls as the square
# of the table length, so going from 256 to 1024 points takes the
# oscillator's own distortion down by about 24 dB, from roughly -71 dB to
# roughly -95 dB, for no extra work at render time. It is still one
# two-point interpolation per sample, just on a finer grid. The only cost
# is flash, which this target has in abundance.
TABLE_OUT = 1024

# Pitch zones, matching the 8-semitone spacing Tresses uses for its own
# band-limited tables. Zone 0 starts at MIDI key 18.
FIRST_KEY = 18
KEYS_PER_ZONE = 8
ZONE_COUNT = 15

# A little below true Nyquist, so the highest kept harmonic is not sitting
# right on the edge.
HARMONIC_CEILING = 15800.0

# In the order the Chord engine's Waveforms array lists them.
WAVEFORMS = [
    "WAV_Sine",
    "WAV_Sine_Warp1",
    "WAV_Sine_Warp2",
    "WAV_Sine_Warp3",
    "WAV_Triangle",
    "WAV_Sawtooth",
    "WAV_Chip_Pulse_25",
    "WAV_Chip_Pulse_50",
    "WAV_Chip_Triangle",
    "WAV_Screech",
    "WAV_Combined_Sin_Saw",
    "WAV_Combined_Trig_Sin",
    "WAV_Combined_Square_Sin",
]

RESOURCES = ("device/alire/cache/pins/tresses/src/"
             "tresses-resources--SR32000.ads")
OUTPUT = "common/generated/wnm-voices-chord_wavetables.ads"

S16_LIMIT = 32766


def key_of_zone_top(zone):
    return FIRST_KEY + KEYS_PER_ZONE * zone + (KEYS_PER_ZONE - 1)


def freq_of_key(key):
    return 440.0 * 2.0 ** ((key - 69) / 12.0)


def harmonic_limit(zone):
    """Highest harmonic that still fits under the ceiling for this zone."""
    top = freq_of_key(key_of_zone_top(zone))
    return max(1, min(MAX_HARMONIC, int(math.floor(HARMONIC_CEILING / top))))


def parse_tables(path):
    """Pull each named Table_257_S16 out of the Tresses resources spec."""
    text = open(path).read()
    lines = text.splitlines()
    tables = {}
    for name in WAVEFORMS:
        start = None
        pattern = re.compile(r"\s*" + re.escape(name) + r"\s*:")
        for i, line in enumerate(lines):
            if pattern.match(line) and "Table_257_S16" in line:
                start = i
                break
        if start is None:
            sys.exit("could not find %s in %s" % (name, path))
        values = []
        for line in lines[start + 1:]:
            values.extend(int(v) for v in re.findall(r"-?\d+", line))
            if len(values) >= TABLE_SIZE + 1:
                break
        tables[name] = values[:TABLE_SIZE + 1]
    return tables


def spectrum(period):
    """Harmonic coefficients 0 .. TABLE_SIZE/2 of one period."""
    n = TABLE_SIZE
    twiddle = [cmath.exp(-2j * math.pi * i / n) for i in range(n)]
    coeffs = []
    for k in range(MAX_HARMONIC + 1):
        total = 0j
        for i, sample in enumerate(period):
            total += sample * twiddle[(k * i) % n]
        coeffs.append(total / n)
    return coeffs


COS_T = [math.cos(2 * math.pi * i / TABLE_OUT) for i in range(TABLE_OUT)]
SIN_T = [math.sin(2 * math.pi * i / TABLE_OUT) for i in range(TABLE_OUT)]


def band_limited(coeffs, limit):
    """Resample one period onto TABLE_OUT points, harmonics up to limit.

    The coefficients describe a continuous periodic function, so evaluating
    it on a finer grid is exact rather than interpolated. That is what buys
    the resolution: no guessing between the original 256 points.
    """
    out = []
    top = min(limit, MAX_HARMONIC - 1)
    for i in range(TABLE_OUT):
        acc = coeffs[0].real
        for k in range(1, top + 1):
            idx = (k * i) % TABLE_OUT
            acc += 2.0 * (coeffs[k].real * COS_T[idx]
                          - coeffs[k].imag * SIN_T[idx])
        if limit >= MAX_HARMONIC:
            # The top bin is shared between positive and negative
            # frequencies, so it is not doubled.
            idx = (MAX_HARMONIC * i) % TABLE_OUT
            acc += coeffs[MAX_HARMONIC].real * COS_T[idx]
        value = int(round(acc))
        out.append(max(-S16_LIMIT, min(S16_LIMIT, value)))
    # Final point closes the loop. Band limiting removes any discontinuity,
    # so the period ends where it began.
    out.append(out[0])
    return out


def format_table(name, values):
    lines = ["   %s : aliased constant Table_1025_S16 := (" % name]
    for start in range(0, len(values), 8):
        chunk = values[start:start + 8]
        body = ", ".join("%6d" % v for v in chunk)
        tail = "," if start + 8 < len(values) else ");"
        lines.append("     " + body + tail)
    return "\n".join(lines)


def main():
    if not os.path.isfile(RESOURCES):
        sys.exit("run this from the repo root, cannot see " + RESOURCES)

    originals = parse_tables(RESOURCES)

    limits = [harmonic_limit(z) for z in range(ZONE_COUNT)]
    print("harmonic limit per zone:", limits)

    # name -> generated table name, deduplicated by content
    generated = []
    by_content = {}
    # [wave][zone] -> Ada expression for the table access
    picks = []

    for wave in WAVEFORMS:
        period = originals[wave][:TABLE_SIZE]
        coeffs = None
        row = []
        for zone in range(ZONE_COUNT):
            limit = limits[zone]
            if coeffs is None:
                coeffs = spectrum(period)
            values = band_limited(coeffs, limit)
            key = tuple(values)
            name = by_content.get(key)
            if name is None:
                name = "%s_BL%d" % (wave, limit)
                by_content[key] = name
                generated.append((name, values))
            row.append("%s'Access" % name)
        picks.append(row)
        print("  %-26s %d generated" % (wave, len(set(row))))

    out = []
    out.append("--  Generated by scripts/gen_chord_wavetables.py.")
    out.append("--  Do not edit by hand, re-run the script instead.")
    out.append("--")
    out.append("--  Band-limited copies of the Chord engine's waveforms,")
    out.append("--  one per pitch zone. Reading a single table at every")
    out.append("--  pitch folds the harmonics that sit above Nyquist back")
    out.append("--  down as inharmonic partials, which is heard as fizz and")
    out.append("--  slow beating that worsens with pitch. Each copy here has")
    out.append("--  those harmonics already removed for the top of its zone.")
    out.append("--  Zones that need no removal point at the original table,")
    out.append("--  so low notes are unchanged.")
    out.append("")
    out.append("with Interfaces;")
    out.append("with MIDI;")
    out.append("")
    out.append("package WNM.Voices.Chord_Wavetables is")
    out.append("   pragma Style_Checks (Off);")
    out.append("")
    out.append("   --  The sample values below are Integer_16, which is what")
    out.append("   --  Tresses.S16 is a subtype of, so its operators need to")
    out.append("   --  be visible here for the negative literals to compile.")
    out.append("   use type Interfaces.Integer_16;")
    out.append("")
    out.append("   Points_Per_Period : constant := %d;" % TABLE_OUT)
    out.append("")
    out.append("   type Table_1025_S16 is array")
    out.append("     (Interfaces.Unsigned_16 range 0 .. %d)" % TABLE_OUT)
    out.append("     of Interfaces.Integer_16;")
    out.append("   --  One period plus a closing point, so interpolating")
    out.append("   --  between index N and N + 1 never runs off the end.")
    out.append("")
    out.append("   type Zone_Index is range 0 .. %d;" % (ZONE_COUNT - 1))
    out.append("   type Wave_Index is range 0 .. %d;" % (len(WAVEFORMS) - 1))
    out.append("")
    out.append("   type Table_Access is")
    out.append("     not null access constant Table_1025_S16;")
    out.append("")

    zone_of_key = []
    for key in range(128):
        zone = (key - FIRST_KEY) // KEYS_PER_ZONE
        zone_of_key.append(max(0, min(ZONE_COUNT - 1, zone)))

    out.append("   Zone_Of_Key : constant array (MIDI.MIDI_Key)")
    out.append("     of Zone_Index :=")
    rows = []
    for start in range(0, 128, 16):
        rows.append("     " + ", ".join("%2d" % z
                                        for z in zone_of_key[start:start + 16]))
    out.append("    (" + ",\n".join(rows).lstrip() + ");")
    out.append("")

    for name, values in generated:
        out.append(format_table(name, values))
        out.append("")

    out.append("   Tables : constant array (Wave_Index, Zone_Index)")
    out.append("     of Table_Access :=")
    rows = []
    for row in picks:
        entries = ",\n".join("       " + e for e in row)
        rows.append("      (\n" + entries + ")")
    out.append("     (" + ",\n".join(rows).lstrip() + ");")
    out.append("")
    out.append("end WNM.Voices.Chord_Wavetables;")

    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "w") as f:
        f.write("\n".join(out) + "\n")

    print("wrote %s (%d generated tables, %d bytes of flash)"
          % (OUTPUT, len(generated), len(generated) * (TABLE_OUT + 1) * 2))


if __name__ == "__main__":
    main()
