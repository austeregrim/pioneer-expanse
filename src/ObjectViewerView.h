// Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
// Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

#ifndef _OBJECTVIEWERVIEW_H
#define _OBJECTVIEWERVIEW_H

#include "Camera.h"
#include "View.h"
#include "galaxy/StarSystem.h"

#include <memory>

class Body;
class SystemBody;

class ObjectViewerView : public View {
public:
	ObjectViewerView();
	~ObjectViewerView() override;
	void Update() override;
	void Draw3D() override;

	void SetTargetBody(Body *body);
	void SetTargetSystemBody(RefCountedPtr<StarSystem> system, SystemBody *sbody);
	void SetReturnView(View *view) { m_returnView = view; }

	static bool IsInspectorEnabled();
	static void SetInspectorEnabled(bool enabled);
	static bool HasPreviewTime();
	static double GetPreviewTime();

protected:
	void OnSwitchTo() override;

	void DrawPiGui() override;

private:
	void ClearRemoteTarget();
	void SyncWithMapSelection();
	bool IsRemoteMode() const { return m_remoteBody != nullptr && m_remoteSystem.Valid(); }
	void ValidateTargetBody();
	void ReloadState();
	void ReturnToPreviousView();

	void DrawInfoWindow();
	void DrawControlsWindow();

	RefCountedPtr<StarSystem> m_remoteSystem;
	std::unique_ptr<Body> m_remoteBody;
	Body *m_targetBody;
	const SystemBody *m_systemBody;
	bool m_isTerrainBody;
	bool m_userSelectedBody;
	bool m_explicitTargetOnSwitch;
	View *m_returnView;

	float viewingDist;
	matrix4x4d m_camRot;

	// Planet Inspector camera & visual debug controls
	bool m_surfaceMode;
	bool m_showAxes;
	bool m_overrideSun;
	double m_latDeg;
	double m_lonDeg;
	double m_altitudeM;
	float m_headingDeg;
	float m_pitchDeg;
	float m_rollDeg;
	float m_sunElevDeg;
	float m_sunAzimDeg;
	float m_lastBgIntensity;
	bool m_ignoreEscFirstFrame;

	// Custom time/date preview
	bool m_useCustomTime;
	double m_customTime;

	// High-res scenic screenshot capture
	int m_screenshotScaleIndex; // 0=1x, 1=2x, 2=4x
	int m_pendingCaptureScale;
	bool m_ssIncludeLabel;
	bool m_ssIncludeTelemetry;
	std::string m_lastScreenshotMsg;

	RefCountedPtr<CameraContext> m_cameraContext;
	std::unique_ptr<Camera> m_camera;
};

#endif /* _OBJECTVIEWERVIEW_H */
