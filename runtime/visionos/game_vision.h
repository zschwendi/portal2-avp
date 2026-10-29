#pragma once
// One engine lifetime per app process. 0 idle, 1 starting/running, 2 returned,
// -1 missing retail/prepared files. Displayed GPU frames are tracked separately.
int p2_vision_game_start(void);
int p2_vision_game_state(void);
