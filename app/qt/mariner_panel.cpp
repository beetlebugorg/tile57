#include "mariner_panel.hpp"

#include <QCheckBox>
#include <QComboBox>
#include <QDoubleSpinBox>
#include <QFormLayout>
#include <QGroupBox>
#include <QLabel>
#include <QVBoxLayout>

namespace cpn {

namespace {
QDoubleSpinBox *metresBox(double value) {
    auto *b = new QDoubleSpinBox;
    b->setRange(0.0, 200.0);
    b->setDecimals(1);
    b->setSingleStep(1.0);
    b->setSuffix(QStringLiteral(" m"));
    b->setValue(value);
    return b;
}
} // namespace

MarinerPanel::MarinerPanel(const chartstyle::MarinerSettings &initial, QWidget *parent)
    : QWidget(parent), s_(initial) {
    setMinimumWidth(280);

    // Consistent breathing room for every group's form.
    const auto tidyForm = [](QFormLayout *f) {
        f->setContentsMargins(12, 10, 12, 12);
        f->setHorizontalSpacing(12);
        f->setVerticalSpacing(8);
        f->setLabelAlignment(Qt::AlignRight | Qt::AlignVCenter);
        f->setFieldGrowthPolicy(QFormLayout::ExpandingFieldsGrow);
    };

    auto *root = new QVBoxLayout(this);
    root->setContentsMargins(12, 12, 12, 12);
    root->setSpacing(14);

    // -- Palette --
    auto *palBox = new QGroupBox(QStringLiteral("Palette"));
    auto *palForm = new QFormLayout(palBox);
    tidyForm(palForm);
    scheme_ = new QComboBox;
    scheme_->addItems({QStringLiteral("Day"), QStringLiteral("Dusk"), QStringLiteral("Night")});
    scheme_->setCurrentIndex(static_cast<int>(s_.scheme));
    palForm->addRow(QStringLiteral("Colour scheme"), scheme_);
    root->addWidget(palBox);

    // -- Depth --
    auto *depthBox = new QGroupBox(QStringLiteral("Depth"));
    auto *depthForm = new QFormLayout(depthBox);
    tidyForm(depthForm);
    depthUnit_ = new QComboBox;
    depthUnit_->addItems({QStringLiteral("Metres"), QStringLiteral("Feet")});
    depthUnit_->setCurrentIndex(static_cast<int>(s_.depthUnit));
    depthForm->addRow(QStringLiteral("Units"), depthUnit_);
    fourShades_ = new QCheckBox(QStringLiteral("Four depth shades"));
    fourShades_->setChecked(s_.fourShadeWater);
    depthForm->addRow(fourShades_);
    shallow_ = metresBox(s_.shallowContour);
    depthForm->addRow(QStringLiteral("Shallow contour"), shallow_);
    safety_ = metresBox(s_.safetyContour);
    depthForm->addRow(QStringLiteral("Safety contour"), safety_);
    deep_ = metresBox(s_.deepContour);
    depthForm->addRow(QStringLiteral("Deep contour"), deep_);
    safetyDepth_ = metresBox(s_.safetyDepth);
    depthForm->addRow(QStringLiteral("Safety depth"), safetyDepth_);
    root->addWidget(depthBox);

    // -- Overlays --
    auto *ovBox = new QGroupBox(QStringLiteral("Overlays"));
    auto *ovForm = new QVBoxLayout(ovBox);
    ovForm->setContentsMargins(12, 10, 12, 12);
    ovForm->setSpacing(8);
    dataQuality_ = new QCheckBox(QStringLiteral("Data quality (CATZOC)"));
    dataQuality_->setChecked(s_.dataQuality);
    ovForm->addWidget(dataQuality_);
    infoCallouts_ = new QCheckBox(QStringLiteral("Information callouts"));
    infoCallouts_->setChecked(s_.showInformCallouts);
    ovForm->addWidget(infoCallouts_);
    root->addWidget(ovBox);

    root->addStretch(1);

    // Every control funnels through pull(): read all controls into s_, emit changed.
    const auto onCombo = [this](int) { pull(); };
    const auto onCheck = [this](bool) { pull(); };
    const auto onSpin = [this](double) { pull(); };
    connect(scheme_, &QComboBox::currentIndexChanged, this, onCombo);
    connect(depthUnit_, &QComboBox::currentIndexChanged, this, onCombo);
    connect(fourShades_, &QCheckBox::toggled, this, onCheck);
    connect(dataQuality_, &QCheckBox::toggled, this, onCheck);
    connect(infoCallouts_, &QCheckBox::toggled, this, onCheck);
    for (auto *b : {shallow_, safety_, deep_, safetyDepth_})
        connect(b, &QDoubleSpinBox::valueChanged, this, onSpin);
}

void MarinerPanel::pull() {
    s_.scheme = static_cast<chartstyle::Scheme>(scheme_->currentIndex());
    s_.depthUnit = static_cast<chartstyle::DepthUnit>(depthUnit_->currentIndex());
    s_.fourShadeWater = fourShades_->isChecked();
    s_.shallowContour = shallow_->value();
    s_.safetyContour = safety_->value();
    s_.deepContour = deep_->value();
    s_.safetyDepth = safetyDepth_->value();
    s_.dataQuality = dataQuality_->isChecked();
    s_.showInformCallouts = infoCallouts_->isChecked();
    emit changed(s_);
}

} // namespace cpn
