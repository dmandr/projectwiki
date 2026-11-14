import unittest
from unittest.mock import Mock,patch
import updates

class UpdatesTest(unittest.TestCase):
    def manager(self):
        m=Mock();m.labels.return_value=[];m.name.return_value='wiki';m.owned.return_value={'Image':'sha256:old','Config':{'Image':'old:tag','Env':['TOKEN=secret']},'HostConfig':{'Binds':['book:/wiki']},'State':{'Running':True,'Health':{'Status':'healthy'}}};m.rpc.return_value={'result':{}};return m
    def release(self):return {'image':'ghcr.io/dmandr/projectbook@sha256:new','revision':'a'*40,'version':'a'*12,'configs':{'amd64':'sha256:new'}}
    @patch('updates.docker_api')
    @patch('updates.latest')
    def test_success_preserves_mounts_and_environment(self,latest,api):
        latest.return_value=self.release();m=self.manager();updates.update(m,{'id':'x','update_target':self.release()['image']})
        body=next(c.args[2] for c in api.call_args_list if '/create?' in c.args[1]);self.assertEqual(body['Config'] if 'Config' in body else body['Env'],['TOKEN=secret']);self.assertEqual(body['HostConfig']['Binds'],['book:/wiki']);self.assertEqual(m.registry.update.call_args.kwargs['state'],'ready')
    @patch('updates.docker_api')
    @patch('updates.latest')
    def test_failure_restores_previous_container(self,latest,api):
        latest.return_value=self.release();m=self.manager();m.owned.return_value['State']['Running']=False
        updates.update(m,{'id':'x','update_target':self.release()['image']})
        self.assertEqual(m.registry.update.call_args.kwargs['update_phase'],'rolled_back');m.docker.run.assert_any_call('rm','-f','wiki');m.docker.run.assert_any_call('start','wiki')
    @patch('updates.latest')
    def test_changed_release_does_not_stop_book(self,latest):
        latest.return_value=self.release();m=self.manager()
        with self.assertRaises(updates.Problem):updates.update(m,{'id':'x','update_target':'old-target'})
        m.docker.run.assert_not_called()
    @patch('updates.docker_api')
    def test_interruption_restores_checkpoint(self,api):
        m=self.manager();updates.recover(m,{'id':'x','update_backup':'wiki-rollback-1'})
        api.assert_called_with('POST','/containers/wiki-rollback-1/rename?name=wiki');m.docker.run.assert_any_call('start','wiki')
    def test_pinned_manifest_reference_is_up_to_date(self):
        m=self.manager();m.owned.return_value['Config']['Image']=self.release()['image'];m.docker.inspect.return_value={'Architecture':'amd64','Config':{'Labels':{}}}
        self.assertFalse(updates.version(m,{'id':'x'},self.release())['available'])

    def test_same_platform_image_is_up_to_date(self):
        m=self.manager();m.docker.inspect.return_value={'Architecture':'amd64','Config':{'Labels':{}}};r=self.release();r['configs']['amd64']='sha256:old';self.assertFalse(updates.version(m,{'id':'x'},r)['available'])
    @patch('updates.requests.get')
    @patch('updates.docker_api')
    def test_qdrant_upgrade_uses_new_volume_and_retains_original(self,api,get):
        m=self.manager();m.owned.return_value['HostConfig']['Mounts']=[{'Type':'volume','Source':'vectors','Target':'/qdrant/storage'}];m.docker.inspect.return_value={'Id':'sha256:new'};get.return_value.status_code=200
        updates.prepare_dependency(m,{'id':'x'},{'qdrant_image':'qdrant/qdrant:v1.20.0'})
        body=next(c.args[2] for c in api.call_args_list if '/create?' in c.args[1]);self.assertTrue(body['HostConfig']['Mounts'][0]['Source'].startswith('vectors-upgrade-'))
        self.assertEqual(m.owned.return_value['HostConfig']['Mounts'][0]['Source'],'vectors')
    def test_matching_qdrant_does_not_restart_database(self):
        m=self.manager();m.docker.inspect.return_value={'Id':'sha256:old'}
        updates.prepare_dependency(m,{'id':'x'},{'qdrant_image':'qdrant/qdrant:v1.20.0'})
        self.assertEqual(m.docker.run.call_count,1)
    @patch('updates.version',return_value={'available':True})
    @patch('updates.update')
    @patch('updates.latest')
    def test_combined_updates_both_roles(self,latest,update,version):
        from manager import Registry
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            m=self.manager();m.registry=Registry(folder);b={'id':'x','state':'ready','indexing':True,'update_targets':{'wiki':'wiki-image','rag':'rag-image'}};m.registry.data['books']['x']=b
            latest.side_effect=lambda role:{'image':role+'-image'}
            def apply(manager,book):manager.registry.update('x',update_phase='complete',update_backup=book['update_role']+'-backup')
            update.side_effect=apply;updates.update_book(m,b)
            self.assertEqual([c.args[1]['update_role'] for c in update.call_args_list],['wiki','rag']);self.assertFalse(m.registry.get('x')['bundle_active'])
