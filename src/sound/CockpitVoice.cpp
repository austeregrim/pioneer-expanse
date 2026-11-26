// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "CockpitVoice.h"

#include "GameConfig.h"
#include "Pi.h"
#include "Sound.h"
#include "utils.h"

#include <algorithm>
#include <deque>
#include <unordered_map>

namespace Sound {
	namespace CockpitVoice {

		namespace {
			struct QueuedLine {
				std::string eventId;
				Priority priority;
			};

			constexpr size_t MAX_QUEUE_SIZE = 4;

			Sound::Event s_activeVoice;
			std::string s_activeEventId;
			std::deque<QueuedLine> s_queue;
			std::unordered_map<std::string, double> s_lastPlayedTime;
			double s_clockSec = 0.0;

			std::string BuildSampleKey(const std::string &eventId)
			{
				std::string pack = Pi::config ? Pi::config->String("CockpitVoicePack", "aria") : "aria";
				if (pack.empty())
					pack = "aria";
				return "voice_" + pack + "_" + eventId;
			}
		} // namespace

		void Enqueue(const std::string &eventId, Priority priority, float cooldownSec)
		{
			if (eventId.empty())
				return;
			if (Pi::config && (Pi::config->Int("DisableSound") != 0 || Pi::config->Int("CockpitVoiceEnabled", 1) == 0))
				return;

			// Deduplicate against currently speaking line or queued line
			if (s_activeVoice.IsPlaying() && s_activeEventId == eventId)
				return;
			for (const QueuedLine &item : s_queue) {
				if (item.eventId == eventId)
					return;
			}

			auto cdIt = s_lastPlayedTime.find(eventId);
			if (cdIt != s_lastPlayedTime.end() && (s_clockSec - cdIt->second) < double(cooldownSec))
				return;

			// If a CRITICAL line arrives, purge lower-priority queued lines so it speaks next
			if (priority == Priority::CRITICAL) {
				while (!s_queue.empty() && s_queue.back().priority < Priority::CRITICAL)
					s_queue.pop_back();
			}

			if (s_queue.size() >= MAX_QUEUE_SIZE) {
				// Find lowest-priority queued item to replace if incoming priority is higher
				auto minIt = std::min_element(s_queue.begin(), s_queue.end(),
					[](const QueuedLine &a, const QueuedLine &b) {
						return int(a.priority) < int(b.priority);
					});
				if (minIt != s_queue.end() && int(priority) > int(minIt->priority)) {
					s_queue.erase(minIt);
				} else {
					return;
				}
			}

			// Insert sorted by descending priority (stable among equal priorities)
			auto insertPos = s_queue.end();
			for (auto it = s_queue.begin(); it != s_queue.end(); ++it) {
				if (int(priority) > int(it->priority)) {
					insertPos = it;
					break;
				}
			}
			s_queue.insert(insertPos, QueuedLine{ eventId, priority });
		}

		void Update(float delta_t)
		{
			s_clockSec += std::max(0.0, double(delta_t));

			if (Pi::config && (Pi::config->Int("DisableSound") != 0 || Pi::config->Int("CockpitVoiceEnabled", 1) == 0)) {
				if (!s_queue.empty() || s_activeVoice.IsPlaying())
					Clear();
				return;
			}

			if (s_activeVoice.IsPlaying())
				return;

			s_activeEventId.clear();
			if (s_queue.empty())
				return;

			QueuedLine next = std::move(s_queue.front());
			s_queue.pop_front();

			const float voiceVol = Pi::config ? Clamp(Pi::config->Float("CockpitVoiceVolume", 0.85f), 0.0f, 1.0f) : 0.85f;
			if (voiceVol <= 0.005f)
				return;

			const std::string key = BuildSampleKey(next.eventId);
			s_activeVoice.Play(key.c_str(), voiceVol, voiceVol, 0);
			s_activeEventId = next.eventId;
			s_lastPlayedTime[next.eventId] = s_clockSec;
		}

		void Clear()
		{
			s_queue.clear();
			if (s_activeVoice.IsPlaying())
				s_activeVoice.Stop();
			s_activeEventId.clear();
		}

	} // namespace CockpitVoice
} // namespace Sound
