import { useState } from 'react';
import { Settings, MessageSquare } from 'lucide-react';
import { ChatInterface } from './components/ChatInterface';
import { SettingsModal } from './components/SettingsModal';
import { streamChat, type Message } from './lib/api';

function App() {
  const [messages, setMessages] = useState<Message[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [isSettingsOpen, setIsSettingsOpen] = useState(false);

  const [apiKey, setApiKey] = useState(() => localStorage.getItem('llm_api_key') || '');
  const [model, setModel] = useState(() => localStorage.getItem('llm_model') || 'local-llm');

  const handleSendMessage = async (content: string) => {
    if (!apiKey) {
      setIsSettingsOpen(true);
      return;
    }

    const newMessage: Message = { role: 'user', content };
    const updatedMessages = [...messages, newMessage];
    setMessages(updatedMessages);
    setIsLoading(true);

    let assistantMessage = '';

    // Add placeholder message
    setMessages(prev => [...prev, { role: 'assistant', content: '' }]);

    await streamChat(
      updatedMessages,
      model,
      apiKey,
      (chunk) => {
        assistantMessage += chunk;
        setMessages(prev => {
          const newMessages = [...prev];
          newMessages[newMessages.length - 1] = {
            role: 'assistant',
            content: assistantMessage
          };
          return newMessages;
        });
      },
      () => setIsLoading(false),
      (error) => {
        console.error(error);
        setIsLoading(false);
        setMessages(prev => [
          ...prev,
          { role: 'system', content: `Error: ${error.message}` }
        ]);
      }
    );
  };

  const handleSaveSettings = (newKey: string, newModel: string) => {
    setApiKey(newKey);
    setModel(newModel);
    localStorage.setItem('llm_api_key', newKey);
    localStorage.setItem('llm_model', newModel);
  };

  const handleClearChat = () => {
    if (confirm('Are you sure you want to clear the chat history?')) {
      setMessages([]);
    }
  };

  return (
    <div className="flex h-screen bg-gray-50 dark:bg-gray-900 text-gray-900 dark:text-gray-100 font-sans">
      {/* Sidebar - Hidden on mobile by default */}
      <div className="hidden md:flex w-64 flex-col border-r border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900">
        <div className="p-4 border-b border-gray-200 dark:border-gray-800 flex items-center gap-2 font-bold text-lg">
          <MessageSquare className="text-blue-500" />
          <span>Local LLM</span>
        </div>

        <div className="flex-1 overflow-y-auto p-2">
          <button
            onClick={handleClearChat}
            className="w-full text-left px-4 py-2 rounded-md hover:bg-gray-100 dark:hover:bg-gray-800 text-sm transition-colors"
          >
            + New Chat
          </button>
        </div>

        <div className="p-4 border-t border-gray-200 dark:border-gray-800">
          <button
            onClick={() => setIsSettingsOpen(true)}
            className="flex items-center gap-2 text-sm text-gray-500 hover:text-gray-900 dark:hover:text-gray-100 transition-colors w-full"
          >
            <Settings size={18} />
            Settings
          </button>
        </div>
      </div>

      {/* Main Content */}
      <div className="flex-1 flex flex-col min-w-0">
        <header className="md:hidden flex items-center justify-between p-4 border-b border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900">
          <span className="font-bold flex items-center gap-2">
            <MessageSquare className="text-blue-500" />
            Local LLM
          </span>
          <div className="flex gap-2">
            <button
              onClick={() => setIsSettingsOpen(true)}
              className="p-2 rounded-md hover:bg-gray-100 dark:hover:bg-gray-800"
            >
              <Settings size={20} />
            </button>
          </div>
        </header>

        <main className="flex-1 overflow-hidden relative">
          <ChatInterface
            messages={messages}
            isLoading={isLoading}
            onSendMessage={handleSendMessage}
          />
        </main>
      </div>

      <SettingsModal
        isOpen={isSettingsOpen}
        onClose={() => setIsSettingsOpen(false)}
        onSave={handleSaveSettings}
        initialApiKey={apiKey}
        initialModel={model}
      />
    </div>
  );
}

export default App;
