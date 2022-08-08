// Info about a single weapon. These are held by the PerPlayerStats and each
// one records information about one of the player's weapons.
// It's also responsible for handling weapon level-ups.
#namespace TFLV;

class ::WeaponInfo : Object play {
  // At the moment "wpn" is used both as a convenient way to remember a reference
  // to the weapon itself, and as the key for the info lookup when the caller has
  // a weapon but not the WeaponInfo.
  // We call it "wpn" rather than "weapon" because ZScript gets super confused
  // if we have both a type and an instance variable in scope with the same name.
  // Sigh.
  Weapon wpn;
  string wpnType;
  ::Upgrade::UpgradeBag upgrades;
  double XP;
  uint maxXP;
  uint level;
  // Tracking for how much this gun does hitscans vs. projectiles.
  // Use doubles rather than uints so that at high values it saturates rather
  // than overflowing.
  double hitscan_shots;
  double projectile_shots;

  ::LegendoomWeaponInfo ld_info;

  // Called when a new WeaponInfo is created. This should initialize the entire object.
  void Init(Weapon wpn) {
    DEBUG("Initializing WeaponInfo for %s", TAG(wpn));
    upgrades = new("::Upgrade::UpgradeBag");
    ld_info = new("::LegendoomWeaponInfo");
    ld_info.Init(self);
    Rebind(wpn);
    XP = 0;
    level = 0;
    maxXP = GetXPForLevel(level+1);
    DEBUG("WeaponInfo initialize, class=%s level=%d xp=%d/%d",
        wpnType, level, XP, maxXP);
  }

  // Called when this WeaponInfo is being reassociated with a new weapon. It
  // should keep most of its stats.
  void Rebind(Weapon wpn) {
    self.wpn = wpn;
    self.upgrades.owner = self.wpn.owner;
    if (self.wpnType != wpn.GetClassName()) {
      // Rebinding to a weapon of an entirely different type. Reset the attack
      // modality inference counters.
      self.wpnType = wpn.GetClassName();
      hitscan_shots = 0;
      projectile_shots = 0;
    }
    ld_info.Rebind(self);
    ::RC.GetRC().Configure(self);
  }

  // List of classes that this weapon is considered equivalent to.
  array<string> equivalencies;
  void SetEquivalencies(array<string> classes) {
    equivalencies.copy(classes);
  }

  bool IsEquivalentTo(Weapon wpn) {
    let result = wpn.GetClassName() == self.wpnType
      || equivalencies.find(wpn.GetClassName()) != equivalencies.size();
    DEBUG("Eqv? %s %s -> %d", wpnType, TAG(wpn), result);
    return result;
  }

  // Given another weapon to look at, determine if this WeaponInfo can be rebound
  // to it. The actual logic used depends on the bonsai_upgrade_binding_mode cvar.
  bool CanRebindTo(Weapon wpn) {
    ::UpgradeBindingMode mode = ::Settings.upgrade_binding_mode();

    // Can't rebind at all in BIND_WEAPON mode under normal circumstances.
    // As a special case, we will permit rebinds if:
    // - the new weapon has a different class from the old one;
    // - the old weapon no longer exists;
    // - the two classes are marked equivalent in BONSAIRC.
    if (mode == ::BIND_WEAPON) {
      DEBUG("BIND_WEAPON reuse check: orphaned=%d equivalent=%d",
        self.wpn == null, IsEquivalentTo(wpn));
      return
        self.wpnType != wpn.GetClassName()
        && self.wpn == null
        && IsEquivalentTo(wpn);
    }

    // In class-bound mode, all weapons of the same type share the same WeaponInfo.
    // When you switch weapons, the WeaponInfo for that type gets rebound to the
    // newly wielded weapon.
    if (mode == ::BIND_CLASS) {
      return IsEquivalentTo(wpn);
    }

    // In inheritable weapon-bound mode, a weaponinfo is only reusable if the
    // weapon it was bound to no longer exists.
    if (mode == ::BIND_WEAPON_INHERITABLE) {
      return IsEquivalentTo(wpn) && self.wpn == null;
    }

    ThrowAbortException("Unknown UpgradeBindingMode %d!", mode);
    return false;
  }

  // Heuristics for guessing whether this is a projectile or hitscan weapon.
  // Note that for some weapons, both of these may return true, e.g. in the case
  // of a weapon that has a hitscan primary and projectile alt-fire that both
  // get used frequency.
  // The heuristic we use is that if more than 20% of the attacks made with this
  // weapon are hitscan, it's a hitscan weapon, and similarly for projectile attacks.
  // We have this threshold to limit false positives in the case of e.g. mods
  // that add offhand grenades that get attributed to the current weapon, or
  // weapons that have a projectile alt-fire that is used only very rarely.
  bool IsHitscanWeapon() {
    return hitscan_shots / 4 > projectile_shots;
  }

  bool IsProjectileWeapon() {
    return projectile_shots / 4 > hitscan_shots;
  }

  uint GetXPForLevel(uint level) const {
    uint XP = ::Settings.base_level_cost() * level;
    if (wpn.bMeleeWeapon) {
      XP *= ::Settings.level_cost_mul_for("melee");
    }
    if (wpn.bWimpy_Weapon) {
      XP *= ::Settings.level_cost_mul_for("wimpy");
    }
    // For some reason it can't resolve bExplosive and bBFG
    // if (weapon.bExplosive) {
    //   XP *= ::Settings.level_cost_mul_for("explosive");
    // }
    // if (weapon.bBFG) {
    //   XP *= ::Settings.level_cost_mul_for("bfg");
    // }
    DEBUG("GetXPForLevel: level %d -> XP %.1f", level, XP);
    return XP;
  }

  void AddXP(double newXP) {
    DEBUG("Adding XP: %.3f + %.3f", XP, newXP);
    XP += newXP;
    DEBUG("XP is now %.3f", XP);
    if (XP >= maxXP && XP - newXP < maxXP) {
      Fanfare();
    }
  }

  void Fanfare() {
    wpn.owner.A_Log(
      string.format("Your %s is ready to level up!", wpn.GetTag()),
      true);
    if (::Settings.levelup_flash()) {
      wpn.owner.A_SetBlend("00 80 FF", 0.8, 40);
      wpn.owner.A_SetBlend("00 80 FF", 0.4, 350);
    }
    if (::Settings.levelup_sound() != "") {
      wpn.owner.A_StartSound(::Settings.levelup_sound(), CHAN_AUTO,
        CHANF_OVERLAP|CHANF_UI|CHANF_NOPAUSE|CHANF_LOCAL);
    }
  }

  bool StartLevelUp() {
    if (XP < maxXP) return false;

    let giver = ::WeaponUpgradeGiver(wpn.owner.GiveInventoryType("::WeaponUpgradeGiver"));
    giver.wielded = self;

    if (::Settings.have_legendoom()
        && ::Settings.gun_levels_per_ld_effect() > 0
        && (level % ::Settings.gun_levels_per_ld_effect()) == 0) {
      let ldGiver = ::LegendoomEffectGiver(wpn.owner.GiveInventoryType("::LegendoomEffectGiver"));
      ldGiver.info = self.ld_info;
    }

    return true;
  }

  void FinishLevelUp(::Upgrade::BaseUpgrade upgrade) {
    XP -= maxXP;
    if (!upgrade) {
      // Don't adjust maxXP -- they didn't gain a level.
      wpn.owner.A_Log("Level-up rejected!", true);
      if (XP >= maxXP) Fanfare();
      return;
    }

    ++level;
    ::PerPlayerStats.GetStatsFor(wpn.owner).AddPlayerXP(1);
    maxXP = GetXPForLevel(level+1);
    upgrades.AddUpgrade(upgrade);
    wpn.owner.A_Log(
      string.format("Your %s gained a level of %s!",
        wpn.GetTag(), upgrade.GetName()),
      true);
    if (XP >= maxXP) Fanfare();
  }
}
