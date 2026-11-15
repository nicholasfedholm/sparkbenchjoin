using System;
using System.Linq;
using HarmonyLib;
using Vintagestory.API.Common;
using Vintagestory.API.Server;
using Vintagestory.API.Util;
using Vintagestory.GameContent;

namespace SparkBenchJoin
{
    public class AutoJoin : ModSystem
    {
        ICoreServerAPI sapi;
        bool survival;
        Harmony harmony;
        static ICoreServerAPI sapiStatic;

        public override bool ShouldLoad(EnumAppSide side) { return side == EnumAppSide.Server; }

        public override double ExecuteOrder() { return 0.9; }

        public override void StartServerSide(ICoreServerAPI api)
        {
            sapi = api;
            survival = Environment.GetEnvironmentVariable("SPARKBENCH_SURVIVAL") == "1";
            api.Event.PlayerCreate += OnCreate;
            api.Event.PlayerJoin += OnJoin;
            sapiStatic = api;
            try
            {
                var target = AccessTools.Method(typeof(CharacterSystem), "Event_PlayerJoinServer");
                if (target == null) api.Logger.Error("[sparkbenchjoin] Event_PlayerJoinServer not found, prefix NOT applied");
                else
                {
                    harmony = new Harmony("sparkbenchjoin");
                    harmony.Patch(target, prefix: new HarmonyMethod(typeof(AutoJoin), nameof(JoinPrefix)));
                    api.Logger.Notification("[sparkbenchjoin] harmony patched Event_PlayerJoinServer");
                }
            }
            catch (Exception e) { api.Logger.Error("[sparkbenchjoin] harmony patch failed: " + e); }
            api.Logger.Notification("[sparkbenchjoin] loaded, survival=" + survival);
        }

        public static void JoinPrefix(IServerPlayer byPlayer)
        {
            try
            {
                byte[] cur = byPlayer.GetModdata("createCharacter");
                if (cur == null || !SerializerUtil.Deserialize<bool>(cur, false))
                {
                    byPlayer.SetModdata("createCharacter", SerializerUtil.Serialize(true));
                    sapiStatic?.Logger.Notification("[sparkbenchjoin] prefix: createCharacter=true before vanilla join for " + byPlayer.PlayerName);
                }
            }
            catch (Exception e) { sapiStatic?.Logger.Warning("[sparkbenchjoin] prefix failed: " + e.Message); }
        }

        public override void Dispose()
        {
            harmony?.UnpatchAll("sparkbenchjoin");
            harmony = null;
        }

        void OnCreate(IServerPlayer p)
        {
            // Same encoding Character.cs reads: SerializerUtil.Deserialize(GetModdata(key), false)
            p.SetModdata("createCharacter", SerializerUtil.Serialize(true));
            sapi.Logger.Notification("[sparkbenchjoin] createCharacter=true set for " + p.PlayerName);
            if (!survival)
            {
                p.WorldData.CurrentGameMode = EnumGameMode.Creative;
                p.WorldData.PickingRange = 100;
                p.BroadcastPlayerData();
                sapi.Logger.Notification("[sparkbenchjoin] gamemode=Creative set for " + p.PlayerName);
            }
            else sapi.Logger.Notification("[sparkbenchjoin] SPARKBENCH_SURVIVAL=1, gamemode unchanged");
        }

        void OnJoin(IServerPlayer p)
        {
            // Vanilla only assigns a default class when didSelect is false; with the flag set it is skipped.
            try
            {
                var ent = p.Entity;
                string cur = ent?.WatchedAttributes.GetString("characterClass");
                var cs = sapi.ModLoader.GetModSystem<CharacterSystem>();
                if (ent != null && cs != null && string.IsNullOrEmpty(cur) && cs.characterClasses.Count > 0)
                {
                    string code = cs.characterClasses.Any(c => c.Code == "commoner") ? "commoner" : cs.characterClasses[0].Code;
                    cs.setCharacterClass(ent, code, true);
                    sapi.Logger.Notification("[sparkbenchjoin] characterClass set to " + code);
                }
                else sapi.Logger.Notification("[sparkbenchjoin] characterClass already '" + cur + "'");
            }
            catch (Exception e)
            {
                sapi.Logger.Warning("[sparkbenchjoin] characterClass step failed: " + e.Message);
            }
            sapi.Logger.Notification("[sparkbenchjoin] join " + p.PlayerName + " gamemode=" + p.WorldData.CurrentGameMode);
        }
    }
}
