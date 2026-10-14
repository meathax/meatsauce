"""Verify and retain the responsible-layer explanation without weakening any gate."""
from pathlib import Path
import hashlib,json
HERE=Path(__file__).resolve().parent; SCOPE=HERE/'next_coupled_scope_v2'
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def pin(p):return {'path':str(p),'sha256':H(p),'bytes':p.stat().st_size}
def main():
  f=SCOPE/'frame0_constant_fixture_recovery_v2';c=SCOPE/'completed_png_diagnosis'
  fixture=json.loads((f/'qualification.json').read_text());png=json.loads((c/'qualification.json').read_text())
  frame0=png['frames'][0]
  assert fixture['build']['exit_code']==0 and fixture['run']['exit_code']==1
  assert fixture['all12_source_pins_exact'] and fixture['actual_vs_transcription']['exact']
  assert fixture['original_native_first_field_vs_steady_fixture']['exact']
  assert fixture['actual_vs_MAME']['different_pixels']==868
  assert frame0['native_vs_PNG']['exact'] and frame0['PNG_vs_pixels']['different_pixels']==868
  assert all(row['native_vs_PNG']['exact'] and row['PNG_vs_pixels']['exact'] for row in png['frames'][1:4])
  assert png['frames'][4]['PNG_vs_pixels']['different_pixels']==32544
  for row in png['frames']:
    for key in ['PNG','completed_RGB','original_pixels_RGB','native_pin']:
      assert H(Path(row[key]['path']))==row[key]['sha256']
  out=SCOPE/'first_buffer_cause';assert not out.exists();out.mkdir()
  result={'schema':'verified_MAME_stale_drawing_buffer_observer_v1','decisive_checks':True,
    'cause':'At MACHINE_NOTIFY_FRAME MAME video.cpp has finished screen updates and update_quads has moved completed pixels into m_curtexture and switched m_curbitmap. screen:pixels()/pixel() use m_curbitmap, so they export the other drawing buffer. screen:snapshot uses completed render texture.',
    'responsible_layer':'MAME reference recorder pixel producer, not native RTL renderer or sprite RAM.',
    'correction':'Use the completed-frame PNG captured by the same stock-MAME callback, decode its lossless RGB and invert only the driver-declared ROT90. Preserve original RGB/Pix32 and do not shift frame labels, hide pixels, or patch native hardware.',
    'bound_scope':'Five retained Super Stingray gameplay checkpoints, plus exact constant-RAM renderer field0 fixture. Dynamic native179 divergence remains pending corrected input replay. No all-frame/whole-game acceptance.',
    'scope_flags':{'first_field_graphics_defect_in_RTL':False,'all_games_graphics_gate':False,'audio_gate':False,'whole_game_gate':False},
    'PNG_qualification':pin(c/'qualification.json'),'fixture_qualification':pin(f/'qualification.json'),
    'completed_RGB_pins':[row['completed_RGB'] for row in png['frames']], 'helper':pin(Path(__file__))}
  q=out/'verification.json';q.write_text(json.dumps(result,indent=2)+'\n')
  files=[pin(q),pin(Path(__file__)),pin(f/'zero_tile_diagnosis.json'),pin(HERE/'diagnose_stingray_zero_tile.py')]
  for name in ['recovered_181','frame0_constant_fixture_recovery_v2','completed_png_diagnosis']:
    files.append(pin(SCOPE/name/'import_manifest.json'))
  manifest={'schema':'verified_stingray_buffer_cause_import_v1','files':files,
     'related_manifests':[pin(SCOPE/name/'import_manifest.json') for name in ['recovered_181','frame0_constant_fixture_recovery_v2','completed_png_diagnosis']],
     'completed_RGB_recovery':result['completed_RGB_pins'],'no_functional_RTL_changes':True}
  m=out/'import_manifest.json';m.write_text(json.dumps(manifest,indent=2)+'\n')
  print(json.dumps({'verified_cause':True,'manifest':pin(m),'completed_RGB_pins':result['completed_RGB_pins']}))
if __name__=='__main__':main()
