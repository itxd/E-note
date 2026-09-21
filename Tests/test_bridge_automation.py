#!/usr/bin/env python3
"""Unit coverage for hourly TODO automation; no Feishu, cloud, or real AI required."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('enote_bridge',ROOT/'bridge/enote_bridge.py')
bridge_module=importlib.util.module_from_spec(spec); spec.loader.exec_module(bridge_module)


class FakeAPI:
    def call(self,*_args,**_kwargs): raise AssertionError('unexpected API call')


class FakeRunner:
    def __init__(self,root,outputs=()): self.root=Path(root).resolve(); self.outputs=list(outputs)
    def workspace(self,value):
        path=Path(value).resolve()
        if not path.is_dir() or not (path==self.root or self.root in path.parents):
            raise bridge_module.BridgeError('outside root')
        return path
    def run(self,*_args,**_kwargs): return self.outputs.pop(0),Path('/dev/null')


class AutomationTests(unittest.TestCase):
    def make_bridge(self,temp,outputs=()):
        config=dict(allowedUsers=['owner'],accountID='account',workspaces=[temp],
                    dataDirectory=str(Path(temp)/'journal'),automation=dict(enabled=True))
        return bridge_module.Bridge(config,api=FakeAPI(),runner=FakeRunner(temp,outputs))

    def test_card_sections_only_expose_user_input_and_structured_approval(self):
        todo=dict(id='todo-id',code='T000001')
        body='existing'+self.make_bridge(self.temp.name).automation_card(todo)+'\nAI records stay here'
        body=bridge_module.replace_section(body,bridge_module.AUTOMATION_INPUT_START,
                                           bridge_module.AUTOMATION_INPUT_END,'workspace: /tmp/project')
        self.assertEqual(bridge_module.section(body,bridge_module.AUTOMATION_INPUT_START,
                                               bridge_module.AUTOMATION_INPUT_END),'workspace: /tmp/project')
        self.assertIn('AI records stay here',body)

    def test_planner_forces_server_risk_when_plan_mentions_ssh(self):
        output=json.dumps(dict(reply='ready',ready=True,risk='local_safe',networkRequired=False,
                               serverAccess=False,serverScope='',plan='Run ssh prod.example uptime'))
        instance=self.make_bridge(self.temp.name,[output])
        result=instance.run_planner(dict(text='inspect'),dict(messages=[]),self.temp.name,'key')
        self.assertEqual(result['risk'],'server')

    def test_server_execution_switch_cannot_bypass_missing_restricted_runner(self):
        config=dict(allowedUsers=['owner'],accountID='account',workspaces=[self.temp.name],
                    dataDirectory=str(Path(self.temp.name)/'journal-server'),
                    automation=dict(enabled=True,allowServerExecution=True))
        with self.assertRaisesRegex(bridge_module.BridgeError,'受限服务器执行器'):
            bridge_module.Bridge(config,api=FakeAPI(),runner=FakeRunner(self.temp.name))

    def test_intake_cannot_select_entire_workspace_root_when_policy_requires_project(self):
        output=json.dumps(dict(reply='ready',ready=True,workspace=self.temp.name))
        instance=self.make_bridge(self.temp.name,[output])
        instance.automation['requireWorkspaceBelowRoot']=True
        with self.assertRaisesRegex(bridge_module.BridgeError,'具体项目目录'):
            instance.run_intake(dict(text='task'),dict(messages=[]),'details','key')

    def test_note_approval_rejects_any_changed_bound_field(self):
        instance=self.make_bridge(self.temp.name)
        record=dict(plan='do it',planSHA256=bridge_module.digest('do it'),workspace=self.temp.name,
                    risk='confirmation_required',planVersion=1,approvalCode='code')
        flow=dict(id='flow-id',noteID='note-id',planVersion=1,approvalCode='code')
        body=instance.automation_card(dict(id='todo-id',code='T000001'))
        approval='''decision: approve
flow: different-flow
plan_version: 1
approval_code: code
plan_sha256: %s
risk: confirmation_required
workspace: %s''' % (record['planSHA256'],self.temp.name)
        body=bridge_module.replace_section(body,bridge_module.AUTOMATION_APPROVAL_START,
                                           bridge_module.AUTOMATION_APPROVAL_END,approval)
        state=dict(plan=json.dumps(record),phase='awaiting_approval')
        with self.assertRaisesRegex(bridge_module.BridgeError,'不一致'):
            instance.consume_note_approval(dict(id='todo-id',code='T000001'),flow,dict(body=body),state)

    def setUp(self): self.temp=tempfile.TemporaryDirectory(prefix='enote-automation-')
    def tearDown(self): self.temp.cleanup()


if __name__=='__main__': unittest.main(verbosity=2)
