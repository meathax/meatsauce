/* SPDX-License-Identifier: GPL-3.0-or-later */

package mra

import (
	"testing"

	"jotego/jtframe/macros"
	. "jotego/jtframe/xmlnode"
)

func Test_button_nocredits(t *testing.T) {
	for _, nocr := range []bool{true, false} {
		macros.MakeFromMap(map[string]string{})
		if nocr { macros.Set("JTFRAME_OSD_NOCREDITS", "") }
		cfg := button_test_cfg(t, "Trigger,Missile,Power", "", 3)
		root := MakeNode("misterromdescription")
		make_buttons(&root, &MachineXML{Name: "apache3"}, cfg, Args{})
		b := root.GetNode("buttons")
		names, def := b.GetAttr("names"), b.GetAttr("default")
		t.Logf("nocredits=%v names=%s default=%s", nocr, names, def)
		wn, wd := "Trigger,Missile,Power,Start,Coin", "A,B,X,Start,Select"
		if !nocr { wn += ",Core credits"; wd += ",-" }
		if names != wn || def != wd { t.Errorf("nocredits=%v got %s / %s", nocr, names, def) }
	}
}
