// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#ifndef DEATH_VIEW_H
#define DEATH_VIEW_H

#include "RefCounted.h"
#include "View.h"

class Camera;
class CameraContext;
class Game;

class DeathView : public View {
public:
	DeathView(Game *game);
	virtual ~DeathView();

	void Init();

	virtual void Update() override;
	virtual void Draw3D() override;
	virtual void DrawPiGui() override;

	float GetDeathTimer() const { return m_deathTimer; }

protected:
	virtual void OnSwitchTo() override;

private:
	RefCountedPtr<CameraContext> m_cameraContext;
	std::unique_ptr<Camera> m_camera;
	float m_cameraDist;
	float m_deathTimer = 0.0f;
	Game *m_game;
};

#endif
