// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#include "Sensors.h"
#include "Body.h"
#include "Game.h"
#include "HudTrail.h"
#include "Pi.h"
#include "Player.h"
#include "Ship.h"
#include "Space.h"
#include "ship/SupercruiseController.h"

#include "profiler/Profiler.h"

Sensors::RadarContact::RadarContact() :
	body(0),
	trail(0),
	distance(0.0),
	iff(IFF_UNKNOWN),
	fresh(true)
{
}

Sensors::RadarContact::RadarContact(Body *b) :
	body(b),
	trail(0),
	distance(0.0),
	iff(IFF_UNKNOWN),
	fresh(true)
{
}

Sensors::RadarContact::~RadarContact()
{
	body = 0;
	delete trail;
}

Color Sensors::IFFColor(IFF iff)
{
	switch (iff) {
	case IFF_NEUTRAL: return Color::BLUE;
	case IFF_ALLY: return Color::GREEN;
	case IFF_HOSTILE: return Color::RED;
	case IFF_UNKNOWN:
	default:
		return Color::GRAY;
	}
}

bool Sensors::ContactDistanceSort(const RadarContact &a, const RadarContact &b)
{
	return a.distance < b.distance;
}

Sensors::Sensors(Ship *owner)
{
	m_owner = owner;
}

Body* Sensors::ChooseTarget(TargetingCriteria crit, const Body* oldTarget )
{
	PROFILE_SCOPED();

	if(!m_owner->IsType(ObjectType::PLAYER))
		return nullptr;

	m_radarContacts.sort(ContactDistanceSort);

	std::vector<Body *> candidates;
	candidates.reserve(m_radarContacts.size());

	for (auto it = m_radarContacts.begin(); it != m_radarContacts.end(); ++it) {
		if (!it->body || it->body->IsDead() || !it->body->IsType(ObjectType::SHIP))
			continue;
		const Ship *otherShip = static_cast<const Ship *>(it->body);
		if (!SupercruiseController::IsShipVisibleToSensors(m_owner, otherShip))
			continue;

		if (crit == TARGET_NEAREST_HOSTILE || crit == CYCLE_HOSTILE) {
			if (it->iff != IFF_HOSTILE)
				continue;
		}
		candidates.push_back(it->body);
	}

	if (candidates.empty())
		return nullptr;

	if (crit == TARGET_NEAREST_HOSTILE || !oldTarget)
		return (crit == CYCLE_ALL_PREV) ? candidates.back() : candidates.front();

	for (size_t i = 0; i < candidates.size(); ++i) {
		if (candidates[i] == oldTarget) {
			if (crit == CYCLE_ALL_PREV) {
				return candidates[(i + candidates.size() - 1) % candidates.size()];
			}
			// CYCLE_HOSTILE / CYCLE_ALL_NEXT advance cleanly and wrap around
			return candidates[(i + 1) % candidates.size()];
		}
	}

	return (crit == CYCLE_ALL_PREV) ? candidates.back() : candidates.front();
}

Sensors::IFF Sensors::CheckIFF(Body *other)
{
	PROFILE_SCOPED();
	//complicated relationship check goes here
	if (other->IsType(ObjectType::SHIP)) {
		Ship* ship = static_cast<Ship*>(other);
		Uint8 rel = m_owner->GetRelations(ship);
		if (rel == 0 || ship->IsAIAttacking(m_owner))
		{
			return IFF_HOSTILE;
		}
		else if (rel == 100)
			return IFF_ALLY;
		return IFF_NEUTRAL;
	} else {
		return IFF_UNKNOWN;
	}
}

void Sensors::Update(float time)
{
	PROFILE_SCOPED();
	if (m_owner != Pi::player) return;

	PopulateStaticContacts(); //no need to do all the time

	//Find nearby contacts, same range as radar scanner. It should use these
	//contacts, worldview labels too.
	const bool ownerInSC = (m_owner->GetFlightState() == Ship::SUPERCRUISE);

	auto registerContact = [&](Body *body) {
		if (body == m_owner || !body->IsType(ObjectType::SHIP)) return;
		if (body->IsDead()) return;
		const Ship *otherShip = static_cast<const Ship *>(body);
		if (!SupercruiseController::IsShipVisibleToSensors(m_owner, otherShip)) return;

		auto cit = m_radarContacts.begin();
		while (cit != m_radarContacts.end()) {
			if (cit->body == body) break;
			++cit;
		}

		//create new contact or refresh old
		if (cit == m_radarContacts.end()) {
			m_radarContacts.push_back(RadarContact());
			RadarContact &rc = m_radarContacts.back();
			rc.body = body;
			rc.iff = CheckIFF(rc.body);
			rc.trail = new HudTrail(rc.body, IFFColor(rc.iff));
		} else {
			cit->fresh = true;
		}
	};

	if (ownerInSC) {
		for (Body *body : Pi::game->GetSpace()->GetBodies()) {
			if (!body || !body->IsType(ObjectType::SHIP)) continue;
			registerContact(body);
		}
	}

	Space::BodyNearList nearby = Pi::game->GetSpace()->GetBodiesMaybeNear(m_owner, 100000.0f);
	for (Body *body : nearby) {
		registerContact(body);
	}

	//update contacts and delete stale ones
	auto it = m_radarContacts.begin();
	while (it != m_radarContacts.end()) {
		const Ship *ship = (it->body && it->body->IsType(ObjectType::SHIP)) ? static_cast<const Ship *>(it->body) : nullptr;
		if (!it->fresh || !it->body || it->body->IsDead() || (ship && !SupercruiseController::IsShipVisibleToSensors(m_owner, ship))) {
			m_radarContacts.erase(it++);
		} else {
			const bool validFlying = !ownerInSC && ship && (Ship::FLYING == ship->GetFlightState());
			const bool validSC = ownerInSC && ship && (Ship::SUPERCRUISE == ship->GetFlightState());
			if (validFlying || validSC) {
				it->distance = m_owner->GetPositionRelTo(it->body).Length();
				it->iff = CheckIFF(it->body);
				it->trail->SetColor(IFFColor(it->iff));
				if (validFlying)
					it->trail->Update(time);
				else
					it->trail->Reset(FrameId::Invalid);
			} else {
				it->trail->Reset(FrameId::Invalid);
			}
			it->fresh = false;
			++it;
		}
	}
}

void Sensors::UpdateIFF(Body *b)
{
	PROFILE_SCOPED();
	if (!b) return;
	for (auto it = m_radarContacts.begin(); it != m_radarContacts.end(); ++it) {
		if (it->body == b) {
			it->iff = CheckIFF(b);
			it->trail->SetColor(IFFColor(it->iff));
		}
	}
}

void Sensors::OnDeleted(const Body *body)
{
	m_radarContacts.remove_if([body](const RadarContact &rc) { return rc.body == body; });
	m_staticContacts.remove_if([body](const RadarContact &rc) { return rc.body == body; });
}

void Sensors::ResetTrails()
{
	PROFILE_SCOPED();
	for (auto it = m_radarContacts.begin(); it != m_radarContacts.end(); ++it)
		it->trail->Reset(Pi::player->GetFrame());
}

void Sensors::ClearContacts()
{
	PROFILE_SCOPED();
	m_radarContacts.clear();
	m_staticContacts.clear();
}

void Sensors::PopulateStaticContacts()
{
	PROFILE_SCOPED();
	m_staticContacts.clear();

	for (Body *b : Pi::game->GetSpace()->GetBodies()) {
		switch (b->GetType()) {
		case ObjectType::STAR:
		case ObjectType::PLANET:
		case ObjectType::SPACESTATION:
			break;
		default:
			continue;
		}
		m_staticContacts.push_back(RadarContact(b));
		RadarContact &rc = m_staticContacts.back();
		rc.fresh = true;
	}
}
