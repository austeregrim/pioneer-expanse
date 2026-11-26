// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#ifndef __COCKPIT_VOICE_H
#define __COCKPIT_VOICE_H

#include <string>

namespace Sound {
	namespace CockpitVoice {

		enum class Priority : int {
			INFO = 0,
			ADVISORY = 1,
			WARNING = 2,
			CRITICAL = 3
		};

		// Enqueue a cockpit AI voice advisory by event id (e.g. "fsd_charging", "temp_critical").
		// Non-overlapping: waits for current line to finish; drops lower-priority queued items if full,
		// and enforces per-event cooldowns to avoid spam.
		void Enqueue(const std::string &eventId, Priority priority = Priority::ADVISORY, float cooldownSec = 6.0f);

		// Advance voice queue and play next pending clip if the active clip has completed.
		void Update(float delta_t);

		// Stop active speech and clear all queued lines.
		void Clear();

	} // namespace CockpitVoice
} // namespace Sound

#endif /* __COCKPIT_VOICE_H */
