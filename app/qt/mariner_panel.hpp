// MarinerPanel — the S-52 mariner-settings control panel (Qt-side UI). Holds a
// tile57_mariner (the canonical settings struct from the tile57 C ABI), exposes the
// display axes as controls, and emits changed() whenever the mariner adjusts one so
// the viewer can rebuild the style live (tile57_build_style).
#pragma once

#include "tile57.h"

#include <QWidget>

class QCheckBox;
class QComboBox;
class QDoubleSpinBox;

namespace cpn {

class MarinerPanel : public QWidget {
    Q_OBJECT
public:
    explicit MarinerPanel(const tile57_mariner &initial, QWidget *parent = nullptr);
    [[nodiscard]] const tile57_mariner &settings() const { return s_; }

signals:
    void changed(const tile57_mariner &settings);

private:
    void pull();  // read controls -> s_, then emit changed()

    tile57_mariner s_;

    QComboBox *scheme_ = nullptr;
    QCheckBox *displayBase_ = nullptr;
    QCheckBox *displayStandard_ = nullptr;
    QCheckBox *displayOther_ = nullptr;
    QComboBox *depthUnit_ = nullptr;
    QCheckBox *fourShades_ = nullptr;
    QDoubleSpinBox *shallow_ = nullptr;
    QDoubleSpinBox *safety_ = nullptr;
    QDoubleSpinBox *deep_ = nullptr;
    QDoubleSpinBox *safetyDepth_ = nullptr;
    QComboBox *boundaryStyle_ = nullptr;
    QCheckBox *simplifiedPoints_ = nullptr;
    QCheckBox *textNames_ = nullptr;
    QCheckBox *lightDescriptions_ = nullptr;
    QCheckBox *textOther_ = nullptr;
    QCheckBox *dataQuality_ = nullptr;
    QCheckBox *infoCallouts_ = nullptr;
    QCheckBox *metaBounds_ = nullptr;
    QCheckBox *isoDangersShallow_ = nullptr;
    QCheckBox *dateDependent_ = nullptr;
    QCheckBox *highlightDate_ = nullptr;
};

} // namespace cpn
